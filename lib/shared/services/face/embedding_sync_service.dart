import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../database/embedding_db.dart';
import '../supabase_client.dart';
import 'face_recognition_service.dart';

class DuplicateFaceException implements Exception {
  const DuplicateFaceException();

  @override
  String toString() => 'Wajah ini sudah terdaftar di akun lain.';
}

/// Syncs face embeddings between SQLite and Supabase.
///
/// SQLite is the fast local cache. Supabase is the backup source, mainly for
/// restoring face data when the user installs the app on a new device.
class EmbeddingSyncService {
  static final EmbeddingSyncService instance = EmbeddingSyncService._();
  EmbeddingSyncService._();

  static const _table = 'face_embeddings';
  static const int renewalReminderDays = 90;
  // Approximate Euclidean distance threshold for cosine similarity 0.93:
  // euc^2 = 2 - 2*cos => euc = sqrt(2 - 2*0.93) ~= 0.374
  static const double _duplicateFaceThreshold = 0.37;
  static double get duplicateFaceThreshold => _duplicateFaceThreshold;

  SupabaseClient get _client => SupabaseClientService.client;

  /// Save a single embedding to SQLite and Supabase.
  ///
  /// The Supabase duplicate check keeps one registered face from being reused
  /// across different accounts. Re-enrollment for the same account is allowed.
  Future<void> saveEmbedding(String employeeId, List<double> embedding) async {
    final normalized = FaceRecognitionService.normalizeEmbedding(embedding);
    final duplicated = await isFaceRegisteredByAnotherAccount(
      employeeId,
      normalized,
    );
    if (duplicated) throw const DuplicateFaceException();

    await EmbeddingDb.instance.upsert(employeeId, normalized);
    await _upsertCloudEmbedding(employeeId, normalized);
  }

  /// Save multiple pose embeddings to SQLite and Supabase.
  Future<void> saveEmbeddings(
    String employeeId,
    List<List<double>> embeddings,
  ) async {
    if (embeddings.isEmpty) {
      throw ArgumentError.value(embeddings, 'embeddings', 'Tidak boleh kosong');
    }

    final normalizedEmbeddings = embeddings
        .map(FaceRecognitionService.normalizeEmbedding)
        .toList(growable: false);

    for (final embedding in normalizedEmbeddings) {
      final duplicated = await isFaceRegisteredByAnotherAccount(
        employeeId,
        embedding,
      );
      if (duplicated) throw const DuplicateFaceException();
    }

    await EmbeddingDb.instance.upsertMulti(employeeId, normalizedEmbeddings);
    await _upsertCloudEmbedding(employeeId, normalizedEmbeddings);
  }

  /// Pull embedding(s) from Supabase and cache them locally.
  Future<List<List<double>>?> fetchAndCacheEmbeddings(String employeeId) async {
    final row = await _client
        .from(_table)
        .select('embedding')
        .eq('employee_id', employeeId)
        .maybeSingle();

    if (row == null) return null;

    final raw = row['embedding'] as String;
    final embeddings = _decodeEmbeddings(raw);
    if (embeddings.isEmpty) return null;

    await EmbeddingDb.instance.upsertMulti(employeeId, embeddings);
    return embeddings;
  }

  /// Backward-compatible single-embedding fetch. Returns first embedding only.
  Future<List<double>?> fetchAndCacheEmbedding(String employeeId) async {
    final list = await fetchAndCacheEmbeddings(employeeId);
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  /// Returns true if embedding exists in Supabase.
  Future<bool> isEnrolledOnCloud(String employeeId) async {
    final row = await _client
        .from(_table)
        .select('employee_id')
        .eq('employee_id', employeeId)
        .maybeSingle();
    return row != null;
  }

  Future<DateTime?> getFaceEnrollmentAt(String employeeId) async {
    final Map<String, dynamic>? row;
    try {
      row = await _client
          .from(_table)
          .select('face_enrollment_at')
          .eq('employee_id', employeeId)
          .maybeSingle();
    } on PostgrestException catch (e) {
      if (_isMissingFaceEnrollmentColumn(e)) return null;
      rethrow;
    }

    final raw = row?['face_enrollment_at']?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<bool> shouldRenewEnrollment(String employeeId) async {
    final enrolledAt = await getFaceEnrollmentAt(employeeId);
    if (enrolledAt == null) return false;

    final age = DateTime.now().difference(enrolledAt);
    return age.inDays >= renewalReminderDays;
  }

  /// Returns true if Supabase finds this face on another account.
  ///
  /// This uses the `find_duplicate_face_owner` RPC from `supabase/schema.sql`.
  /// The client receives only the matching owner id and distance, never another
  /// user's raw biometric embedding.
  Future<bool> isFaceRegisteredByAnotherAccount(
    String employeeId,
    List<double> embedding,
  ) async {
    final result = await _client.rpc(
      'find_duplicate_face_owner',
      params: {
        'query_embedding': jsonEncode(embedding),
        'match_threshold': _duplicateFaceThreshold,
      },
    );

    if (result is! List || result.isEmpty) return false;

    for (final row in result) {
      if (row is! Map) continue;
      final ownerId = row['employee_id']?.toString();
      if (ownerId != null && ownerId != employeeId) return true;
    }
    return false;
  }

  /// Get all embeddings for current user. Checks SQLite first, then Supabase.
  Future<List<List<double>>?> getEmbeddings(String employeeId) async {
    final local = await EmbeddingDb.instance.getMulti(employeeId);
    if (local != null && local.isNotEmpty) return local;

    return fetchAndCacheEmbeddings(employeeId);
  }

  /// Backward-compatible single-embedding getter. Returns first only.
  Future<List<double>?> getEmbedding(String employeeId) async {
    final list = await getEmbeddings(employeeId);
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  Future<void> adaptEmbedding(
    String employeeId,
    List<double> newEmbedding, {
    double minSimilarity = 0.80,
    double maxSimilarity = 0.93,
    double alpha = 0.05,
  }) async {
    final stored = await getEmbeddings(employeeId);
    if (stored == null || stored.isEmpty) return;

    int bestIdx = 0;
    double bestSim = -1;
    for (int i = 0; i < stored.length; i++) {
      final sim = FaceRecognitionService.cosineSimilarity(
        newEmbedding,
        stored[i],
      );
      if (sim > bestSim) {
        bestSim = sim;
        bestIdx = i;
      }
    }

    if (bestSim < minSimilarity || bestSim > maxSimilarity) return;

    final old = stored[bestIdx];
    final blended = List<double>.generate(
      old.length,
      (i) => (1 - alpha) * old[i] + alpha * newEmbedding[i],
    );
    final normalized = FaceRecognitionService.normalizeEmbedding(blended);

    final updated = List<List<double>>.from(stored);
    updated[bestIdx] = normalized;

    await EmbeddingDb.instance.upsertMulti(employeeId, updated);
    _client
        .from(_table)
        .upsert({
          'employee_id': employeeId,
          'embedding': jsonEncode(updated),
          'updated_at': DateTime.now().toIso8601String(),
        })
        .then((_) {})
        .catchError((_) {});
  }

  Future<void> deleteEmbedding(String employeeId) async {
    await EmbeddingDb.instance.delete(employeeId);
    await _client.from(_table).delete().eq('employee_id', employeeId);
  }

  Future<void> _upsertCloudEmbedding(
    String employeeId,
    List<dynamic> embeddings,
  ) async {
    final now = DateTime.now().toIso8601String();
    final payload = <String, dynamic>{
      'employee_id': employeeId,
      'embedding': jsonEncode(embeddings),
      'face_enrollment_at': now,
      'updated_at': now,
    };

    try {
      await _client.from(_table).upsert(payload);
    } on PostgrestException catch (e) {
      if (!_isMissingFaceEnrollmentColumn(e)) rethrow;

      // Older Supabase deployments only have employee_id, embedding, updated_at.
      // Save the biometric backup anyway; renewal reminders stay disabled until
      // the column migration is applied.
      payload.remove('face_enrollment_at');
      await _client.from(_table).upsert(payload);
    }
  }

  static bool _isMissingFaceEnrollmentColumn(PostgrestException e) {
    return e.code == 'PGRST204' &&
        e.message.contains("'face_enrollment_at' column");
  }

  static List<List<double>> _decodeEmbeddings(String raw) {
    final decoded = jsonDecode(raw) as List;
    if (decoded.isEmpty) return [];
    if (decoded.first is List) {
      return decoded
          .map((e) => (e as List).map((n) => (n as num).toDouble()).toList())
          .toList();
    }
    return [decoded.map((e) => (e as num).toDouble()).toList()];
  }
}
