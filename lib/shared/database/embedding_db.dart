import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Local SQLite store for face embeddings.
/// Embedding is stored as JSON array of model-sized normalized doubles.
/// Source of truth is Supabase — this is a local cache for offline-guard
/// and fast lookup without round-trip latency.
///
/// v2: Supports multiple embeddings per user (one per pose)
/// for better matching against varied head poses at attendance time.
class EmbeddingDb {
  static final EmbeddingDb instance = EmbeddingDb._();
  EmbeddingDb._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = join(dir, 'face_embeddings.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE face_embeddings (
            employee_id TEXT PRIMARY KEY,
            embedding   TEXT NOT NULL,
            updated_at  TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        // v1 stored a single embedding (JSON array of doubles).
        // v2 stores either a single embedding OR a list of embeddings — we
        // detect the shape at read time, so no schema migration is needed.
        // The TEXT column is reused as-is.
      },
    );
  }

  /// Save or replace embedding(s) for an employee.
  /// Accepts either a single embedding (`List<double>`) or multiple embeddings
  /// (`List<List<double>>`). Both shapes round-trip through the same column.
  Future<void> upsert(String employeeId, List<double> embedding) async {
    final d = await db;
    await d.insert('face_embeddings', {
      'employee_id': employeeId,
      'embedding': jsonEncode(embedding),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Save multiple embeddings (e.g. front/left/right poses) as a list-of-lists.
  Future<void> upsertMulti(
    String employeeId,
    List<List<double>> embeddings,
  ) async {
    final d = await db;
    await d.insert('face_embeddings', {
      'employee_id': employeeId,
      'embedding': jsonEncode(embeddings),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Get embedding for an employee, or null if not enrolled.
  /// Returns the FIRST embedding if stored as multi — kept for backward compat.
  Future<List<double>?> get(String employeeId) async {
    final list = await getMulti(employeeId);
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  /// Get all embeddings for an employee (1..N entries).
  /// Handles both v1 (single `List<double>`) and v2 (`List<List<double>>`) shapes.
  Future<List<List<double>>?> getMulti(String employeeId) async {
    final d = await db;
    final rows = await d.query(
      'face_embeddings',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['embedding'] as String;
    return _decodeEmbeddings(raw);
  }

  /// Decode a stored embedding payload — supports both shapes:
  ///   [0.1, 0.2, ...]            → single embedding (v1)
  ///   [[0.1, ...], [0.3, ...]]   → multi embedding (v2)
  static List<List<double>> _decodeEmbeddings(String raw) {
    final decoded = jsonDecode(raw) as List;
    if (decoded.isEmpty) return [];
    final first = decoded.first;
    if (first is List) {
      // v2: list of lists
      return decoded
          .map((e) => (e as List).map((n) => (n as num).toDouble()).toList())
          .toList();
    }
    // v1: single list of doubles
    return [decoded.map((e) => (e as num).toDouble()).toList()];
  }

  /// Check if employee has an enrolled embedding.
  Future<bool> isEnrolled(String employeeId) async {
    final d = await db;
    final rows = await d.query(
      'face_embeddings',
      columns: ['employee_id'],
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Delete embedding (e.g. re-enrollment).
  Future<void> delete(String employeeId) async {
    final d = await db;
    await d.delete(
      'face_embeddings',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
    );
  }

  /// Get all stored embeddings (for matching against any employee).
  /// Returns the FIRST embedding per employee — kept for backward compat.
  Future<Map<String, List<double>>> getAll() async {
    final d = await db;
    final rows = await d.query('face_embeddings');
    final result = <String, List<double>>{};
    for (final row in rows) {
      final list = _decodeEmbeddings(row['embedding'] as String);
      if (list.isNotEmpty) {
        result[row['employee_id'] as String] = list.first;
      }
    }
    return result;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
