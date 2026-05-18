import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/app_models.dart';
import '../../../shared/services/attendance_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/supabase_client.dart';
import '../../../shared/providers/notification_provider.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/services/face/embedding_sync_service.dart';
import '../../../shared/services/face/face_recognition_service.dart';
import '../../enrollment/presentation/enrollment_screen.dart';
import 'camera_face_view.dart';

class _VerificationDecision {
  const _VerificationDecision({
    required this.matched,
    required this.bestSimilarity,
    required this.averageSimilarity,
    required this.passCount,
    required this.totalVotes,
    required this.strategy,
  });

  final bool matched;
  final double bestSimilarity;
  final double averageSimilarity;
  final int passCount;
  final int totalVotes;
  final String strategy;
}

class _SampleVerification {
  const _SampleVerification({
    required this.matched,
    required this.bestSimilarity,
    required this.topAverageSimilarity,
    required this.averageSimilarity,
    required this.passCount,
    required this.totalVotes,
    required this.strategy,
  });

  final bool matched;
  final double bestSimilarity;
  final double topAverageSimilarity;
  final double averageSimilarity;
  final int passCount;
  final int totalVotes;
  final String strategy;
}

class AttendanceScreen extends StatefulWidget {
  final bool isActive;

  const AttendanceScreen({super.key, this.isActive = true});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _store = AppStore.instance;
  GlobalKey<CameraFaceViewState> _cameraKey = GlobalKey<CameraFaceViewState>();

  bool _processing = false;
  bool _isEnrolled = false;
  bool _enrollChecked = false;

  bool _checkingFace = false;
  bool _faceMatched = false;
  bool _matchFailed = false;
  bool _renewalPromptShown = false;
  double? _lastSimilarity;
  int _sampleAttempts = 0;
  int _faceResetGeneration = 0;
  double _bestSimilarity = -1.0;
  final List<List<double>> _verificationEmbeddings = [];
  static const int _maxVerificationSamples = 3;
  static const int _maxVerificationCaptures = 4;
  static const int _minMatchedVerificationSamples = 2;
  static const int _poseEmbeddingCount = 4;
  static const double _poseVoteThreshold = 0.88;
  static const double _poseBestThreshold = 0.90;
  static const double _poseTopAverageThreshold = 0.86;
  static const double _minAverageVerificationSimilarity = 0.86;
  static const double _registeredOtherFaceRejectDistance = 0.49;

  DateTime get _today =>
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  AttendanceRecord? get _todayRecord => _store.attendanceOf(_today);
  bool get _isCheckedIn => _todayRecord?.checkIn != null;
  bool get _isCheckedOut => _todayRecord?.checkOut != null;

  @override
  void initState() {
    super.initState();
    _checkEnrollmentStatus();
    FaceRecognitionService.instance.init();
  }

  Future<void> _checkEnrollmentStatus() async {
    if (kIsWeb) {
      setState(() {
        _isEnrolled = true;
        _enrollChecked = true;
      });
      return;
    }

    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    final embeddings = await EmbeddingSyncService.instance.getEmbeddings(uid);
    if (!mounted) return;
    setState(() {
      _isEnrolled = embeddings != null && embeddings.isNotEmpty;
      _enrollChecked = true;
    });
    if (_isEnrolled) {
      unawaited(_maybeShowFaceRenewalReminder(uid));
    }
  }

  Future<void> _maybeShowFaceRenewalReminder(String uid) async {
    if (_renewalPromptShown || !mounted) return;

    bool shouldRenew;
    try {
      shouldRenew = await EmbeddingSyncService.instance.shouldRenewEnrollment(
        uid,
      );
    } catch (_) {
      return;
    }

    if (!shouldRenew || !mounted || _renewalPromptShown) return;
    _renewalPromptShown = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showFaceRenewalDialog());
    });
  }

  // -- Face match callback --------------------------------------------------

  Future<void> _onFaceDetectedForAttendance({
    required img.Image fullImage,
    required Uint8List? nv21Bytes,
    required int rawWidth,
    required int rawHeight,
    required InputImageRotation rotation,
    required Face face,
  }) async {
    if (_processing || _isCheckedOut) return;

    setState(() {
      _checkingFace = true;
      _matchFailed = false;
      _lastSimilarity = null;
      _sampleAttempts++;
    });

    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) return;

      final stored = await EmbeddingSyncService.instance.getEmbeddings(uid);
      if (stored == null || stored.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isEnrolled = false;
          _checkingFace = false;
        });
        _cameraKey.currentState?.resetToReady();
        return;
      }

      final query = nv21Bytes != null
          ? await FaceRecognitionService.instance.extractEmbeddingFromNv21(
              nv21Bytes: nv21Bytes,
              width: rawWidth,
              height: rawHeight,
              rotation: rotation,
              face: face,
            )
          : await FaceRecognitionService.instance.extractEmbedding(
              fullImage,
              face,
            );
      if (query == null) {
        if (_sampleAttempts < _maxVerificationCaptures &&
            _verificationEmbeddings.length < _maxVerificationSamples) {
          await _scanNextFaceSample();
        } else {
          _showFaceMatchFailed('Wajah tidak terbaca dengan jelas.');
        }
        return;
      }

      _verificationEmbeddings.add(query);
      final decision = _verifySamplesAgainstStored(
        _verificationEmbeddings,
        stored,
      );
      _lastSimilarity = decision.bestSimilarity;
      _bestSimilarity = decision.bestSimilarity;

      final enoughMatched =
          decision.passCount >= _minMatchedVerificationSamples;
      final canTryMore =
          _verificationEmbeddings.length < _maxVerificationSamples &&
          _sampleAttempts < _maxVerificationCaptures;
      final hasFullVerificationSamples =
          _verificationEmbeddings.length >= _maxVerificationSamples;

      if ((!hasFullVerificationSamples || !enoughMatched) && canTryMore) {
        _lastSimilarity = _bestSimilarity >= 0 ? _bestSimilarity : null;
        await _scanNextFaceSample();
        return;
      }

      final averageStrongEnough =
          decision.averageSimilarity >= _minAverageVerificationSimilarity;

      if (!hasFullVerificationSamples ||
          !enoughMatched ||
          !decision.matched ||
          !averageStrongEnough) {
        _showFaceMatchFailed(
          'Wajah tidak cukup konsisten dengan data terdaftar. Silakan ulangi.',
        );
        return;
      }

      final otherOwner = await _checkSamplesAgainstOtherRegisteredUsers(
        _verificationEmbeddings,
      );
      if (otherOwner != null && otherOwner != uid) {
        _showFaceMatchFailed(
          'Wajah lebih dekat ke akun lain. Presensi ditolak.',
        );
        return;
      }

      final nearestOwner = await _checkNearestRegisteredFaceOwner(
        _verificationEmbeddings,
      );
      if (nearestOwner != null && nearestOwner != uid) {
        _showFaceMatchFailed(
          'Wajah tidak paling dekat dengan akun ini. Presensi ditolak.',
        );
        return;
      }

      if (!mounted) return;
      setState(() => _faceMatched = true);
      await Future.delayed(const Duration(milliseconds: 450));
      await _recordAttendance();
    } catch (e) {
      if (e is QualityFilterException) {
        if (_sampleAttempts < _maxVerificationCaptures &&
            _verificationEmbeddings.length < _maxVerificationSamples) {
          await _scanNextFaceSample();
        } else {
          _showFaceMatchFailed(e.reason);
        }
      } else {
        // ignore: avoid_print
        print('[Attendance] Error during face match: $e');
        _showFaceMatchFailed('Presensi gagal. Coba lagi.');
      }
    }
  }
  // ── Connectivity check ────────────────────────────────────────────────────

  _VerificationDecision _verifySamplesAgainstStored(
    List<List<double>> samples,
    List<List<double>> stored,
  ) {
    final storedGroups = _poseEmbeddingGroups(stored);
    final storedSelfBest = _storedSelfBestSimilarity(stored);
    final sampleDecisions = samples
        .map(
          (sample) =>
              _verifySingleSample(sample: sample, storedGroups: storedGroups),
        )
        .toList(growable: false);

    final matchedSamples = sampleDecisions.where((d) => d.matched).length;
    final requiredSamples = samples.length >= _maxVerificationSamples
        ? _minMatchedVerificationSamples
        : samples.length;
    final best = sampleDecisions.isEmpty
        ? 0.0
        : sampleDecisions
              .map((d) => d.bestSimilarity)
              .reduce((a, b) => a > b ? a : b);
    final average = sampleDecisions.isEmpty
        ? 0.0
        : sampleDecisions.map((d) => d.bestSimilarity).reduce((a, b) => a + b) /
              sampleDecisions.length;
    final matched =
        sampleDecisions.isNotEmpty && matchedSamples >= requiredSamples;
    final strategy = sampleDecisions.map((d) => d.strategy).join('|');

    final decision = _VerificationDecision(
      matched: matched,
      bestSimilarity: best,
      averageSimilarity: average,
      passCount: matchedSamples,
      totalVotes: sampleDecisions.length,
      strategy: strategy,
    );
    _logVerification(
      decision,
      samples: sampleDecisions,
      storedCount: stored.length,
      comparedGroupCount: storedGroups.length,
      storedSelfBest: storedSelfBest,
    );
    return decision;
  }

  _SampleVerification _verifySingleSample({
    required List<double> sample,
    required Map<String, List<List<double>>> storedGroups,
  }) {
    final representatives = _poseRepresentatives(storedGroups);
    final decisions = representatives.entries
        .map((entry) {
          return _voteSingleSample(
            sample: sample,
            stored: [entry.value],
            threshold: _poseVoteThreshold,
            bestThreshold: _poseBestThreshold,
            topAverageThreshold: _poseTopAverageThreshold,
            requiredPasses: 1,
            strategy: entry.key,
          );
        })
        .toList(growable: false);

    if (decisions.isEmpty) {
      return const _SampleVerification(
        matched: false,
        bestSimilarity: 0,
        topAverageSimilarity: 0,
        averageSimilarity: 0,
        passCount: 0,
        totalVotes: 0,
        strategy: 'none',
      );
    }

    decisions.sort((a, b) {
      final matchedCompare = (b.matched ? 1 : 0) - (a.matched ? 1 : 0);
      if (matchedCompare != 0) return matchedCompare;
      return b.bestSimilarity.compareTo(a.bestSimilarity);
    });
    return decisions.first;
  }

  _SampleVerification _voteSingleSample({
    required List<double> sample,
    required List<List<double>> stored,
    required double threshold,
    required double bestThreshold,
    required double topAverageThreshold,
    required int requiredPasses,
    required String strategy,
  }) {
    final similarities =
        stored
            .map((enrolled) {
              final sim = FaceRecognitionService.cosineSimilarity(
                sample,
                enrolled,
              );
              return sim.clamp(0.0, 1.0);
            })
            .toList(growable: false)
          ..sort((a, b) => b.compareTo(a));

    final best = similarities.isEmpty ? 0.0 : similarities.first;
    final topCount = similarities.length >= 2 ? 2 : similarities.length;
    final topAverage = topCount == 0
        ? 0.0
        : similarities.take(topCount).reduce((a, b) => a + b) / topCount;
    final average = similarities.isEmpty
        ? 0.0
        : similarities.reduce((a, b) => a + b) / similarities.length;
    final passCount = similarities.where((sim) => sim >= threshold).length;
    final voteMatched = similarities.isNotEmpty && passCount >= requiredPasses;
    final strongMatched =
        best >= bestThreshold && topAverage >= topAverageThreshold;
    final matched = voteMatched || strongMatched;

    return _SampleVerification(
      matched: matched,
      bestSimilarity: best,
      topAverageSimilarity: topAverage,
      averageSimilarity: average,
      passCount: passCount,
      totalVotes: similarities.length,
      strategy: strategy,
    );
  }

  double _storedSelfBestSimilarity(List<List<double>> stored) {
    if (stored.length < 2) return 1.0;
    double best = -1.0;
    for (int i = 0; i < stored.length; i++) {
      for (int j = i + 1; j < stored.length; j++) {
        final sim = FaceRecognitionService.cosineSimilarity(
          stored[i],
          stored[j],
        );
        if (sim > best) best = sim;
      }
    }
    return best.clamp(0.0, 1.0);
  }

  void _logVerification(
    _VerificationDecision decision, {
    required List<_SampleVerification> samples,
    required int storedCount,
    required int comparedGroupCount,
    required double storedSelfBest,
  }) {
    final sampleLog = samples
        .map(
          (sample) =>
              '${sample.strategy}:${sample.passCount}/${sample.totalVotes}'
              '@best=${sample.bestSimilarity.toStringAsFixed(4)}'
              '/top=${sample.topAverageSimilarity.toStringAsFixed(4)}',
        )
        .join(',');
    // ignore: avoid_print
    print(
      '[Attendance] verification strategy=${decision.strategy} '
      'groups=$comparedGroupCount stored=$storedCount '
      'storedSelfBest=${storedSelfBest.toStringAsFixed(4)} '
      'samples=${decision.passCount}/${decision.totalVotes} '
      'avg=${decision.averageSimilarity.toStringAsFixed(4)} '
      'best=${decision.bestSimilarity.toStringAsFixed(4)} '
      'matched=${decision.matched} details=[$sampleLog]',
    );
  }

  Map<String, List<List<double>>> _poseEmbeddingGroups(
    List<List<double>> stored,
  ) {
    if (stored.length <= _poseEmbeddingCount) {
      return {'center': stored};
    }

    return {
      'center': stored.take(_poseEmbeddingCount).toList(growable: false),
      'left': stored
          .skip(_poseEmbeddingCount)
          .take(_poseEmbeddingCount)
          .toList(growable: false),
      'right': stored
          .skip(_poseEmbeddingCount * 2)
          .take(_poseEmbeddingCount)
          .toList(growable: false),
    };
  }

  Map<String, List<double>> _poseRepresentatives(
    Map<String, List<List<double>>> groups,
  ) {
    final representatives = <String, List<double>>{};
    final all = <List<double>>[];

    for (final entry in groups.entries) {
      final embeddings = entry.value;
      if (embeddings.isEmpty) continue;
      all.addAll(embeddings);
      representatives[entry.key] = embeddings.length == 1
          ? embeddings.first
          : FaceRecognitionService.bestEmbedding(embeddings);
    }

    if (all.length > 1) {
      representatives['global'] = FaceRecognitionService.bestEmbedding(all);
    }

    return representatives;
  }

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  // ── Tombol Check-In / Check-Out ditekan ───────────────────────────────────

  void _handleButtonTap() {
    if (_isCheckedOut || _processing || _checkingFace) return;
    if (kIsWeb) {
      _manualCheckInOrOut();
      return;
    }

    Future<void> startScan() async {
      final generation = ++_faceResetGeneration;
      final cameraState = _cameraKey.currentState;
      if (cameraState == null) return;

      cameraState.resetToReady();
      await Future.delayed(const Duration(milliseconds: 90));
      if (!mounted || generation != _faceResetGeneration) return;

      setState(() {
        _checkingFace = true;
        _faceMatched = false;
        _matchFailed = false;
        _lastSimilarity = null;
        _sampleAttempts = 0;
        _bestSimilarity = -1.0;
        _verificationEmbeddings.clear();
      });

      final started = _cameraKey.currentState?.startScan() ?? false;
      if (!started && mounted && generation == _faceResetGeneration) {
        _resetFaceVerificationState();
        _showResult(
          success: false,
          message: 'Kamera belum siap. Coba lagi sebentar.',
        );
      }
    }

    if (_isCheckedIn) {
      unawaited(
        _confirmCheckOut().then((confirmed) {
          if (confirmed && mounted) unawaited(startScan());
        }),
      );
      return;
    }

    unawaited(startScan());
  }

  Future<void> _recordAttendance() async {
    setState(() => _processing = true);

    try {
      if (!await _isOnline()) {
        _showResult(
          success: false,
          message: 'Tidak ada koneksi internet.',
          icon: Icons.wifi_off_rounded,
        );
        _resetFaceVerificationState(failed: true);
        _cameraKey.currentState?.resetToReady();
        return;
      }

      final uid = AuthService.instance.currentUserId;
      if (uid == null) {
        _resetFaceVerificationState(failed: true);
        _cameraKey.currentState?.resetToReady();
        return;
      }

      if (!_isCheckedIn) {
        final record = await AttendanceService.instance.checkInWithFaceNonce(
          uid,
          source: AttendanceSource.face,
        );
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        _showResult(
          success: true,
          message: 'Check-in berhasil pukul ${_fmtTod(record.checkIn!)}',
        );
        _showSuccessDialog(
          title: 'Check-In Berhasil',
          message: 'Selamat bekerja. Semoga harimu produktif dan lancar.',
          icon: Icons.work_rounded,
          color: AppColors.success,
        );
      } else {
        final record = await AttendanceService.instance.checkOutWithFaceNonce(
          uid,
        );
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        _cameraKey.currentState?.markDone();
        _showResult(
          success: true,
          message: 'Check-out berhasil pukul ${_fmtTod(record.checkOut!)}',
          color: AppColors.error,
        );
        _showSuccessDialog(
          title: 'Check-Out Berhasil',
          message:
              'Selamat beristirahat. Terima kasih untuk kerja keras hari ini.',
          icon: Icons.nightlight_round,
          color: AppColors.error,
        );
      }

      _resetFaceVerificationState();
      if (!_isCheckedOut) _cameraKey.currentState?.resetToReady();
    } catch (e) {
      // ignore: avoid_print
      print('[Attendance] Failed to save attendance: $e');
      if (mounted) {
        final message = e is PostgrestException
            ? 'Gagal menyimpan presensi: ${e.message}'
            : 'Gagal menyimpan presensi. Coba lagi.';
        _showResult(success: false, message: message);
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _scanNextFaceSample() async {
    if (!mounted || _processing || _isCheckedOut) return;
    setState(() {
      _lastSimilarity = _bestSimilarity >= 0 ? _bestSimilarity : null;
      _matchFailed = false;
      _faceMatched = false;
      _checkingFace = true;
    });
    await Future.delayed(const Duration(milliseconds: 160));
    if (!mounted || _processing || _isCheckedOut) return;
    _cameraKey.currentState?.resetToReady();
    await Future.delayed(const Duration(milliseconds: 60));
    if (!mounted || _processing || _isCheckedOut) return;
    _cameraKey.currentState?.startScan();
  }

  Future<bool> _confirmCheckOut() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Konfirmasi Check-Out',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Sistem akan mengambil foto dan mencocokkan wajah. Lanjutkan check-out sekarang?',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Check-Out',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _manualCheckInOrOut() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    setState(() => _processing = true);
    try {
      if (!_isCheckedIn) {
        final record = await AttendanceService.instance.checkIn(
          uid,
          source: AttendanceSource.manual,
        );
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        _showResult(
          success: true,
          message: 'Check-in berhasil pukul ${_fmtTod(record.checkIn!)}',
        );
      } else {
        final record = await AttendanceService.instance.checkOut(uid);
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        _showResult(
          success: true,
          message: 'Check-out berhasil pukul ${_fmtTod(record.checkOut!)}',
          color: AppColors.error,
        );
      }
    } catch (e) {
      if (mounted) _showResult(success: false, message: 'Gagal: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showResult({
    required bool success,
    required String message,
    Color? color,
    IconData? icon,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor:
            color ?? (success ? AppColors.success : AppColors.error),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            Icon(
              icon ??
                  (success ? Icons.check_circle_rounded : Icons.error_rounded),
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFaceMatchFailed(String message) {
    if (!mounted) return;
    final generation = ++_faceResetGeneration;
    _resetFaceVerificationState(failed: true);
    _showResult(success: false, message: message);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted ||
          _processing ||
          _checkingFace ||
          generation != _faceResetGeneration) {
        return;
      }
      _cameraKey.currentState?.resetToReady();
    });
  }

  Future<void> _showSuccessDialog({
    required String title,
    required String message,
    required IconData icon,
    required Color color,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 30),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Oke',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _resetFaceVerificationState({bool failed = false}) {
    if (!mounted) return;
    setState(() {
      _checkingFace = false;
      _faceMatched = false;
      _matchFailed = failed;
      _lastSimilarity = failed && _bestSimilarity >= 0 ? _bestSimilarity : null;
      _sampleAttempts = 0;
      _bestSimilarity = -1.0;
      _verificationEmbeddings.clear();
    });
  }

  Future<void> _goToEnrollment() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const EnrollmentScreen()),
    );
    if (result == true && mounted) {
      await _checkEnrollmentStatus();
      if (!mounted) return;
      setState(() {
        _isEnrolled = true;
        _cameraKey = GlobalKey<CameraFaceViewState>();
      });
    }
  }

  Future<void> _showFaceRenewalDialog() async {
    final updateNow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Perbarui Data Wajah',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Data wajah Anda sudah lebih dari ${EmbeddingSyncService.renewalReminderDays} hari. '
          'Perbarui agar presensi tetap akurat jika penampilan berubah.',
          style: const TextStyle(
            fontSize: 13,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Nanti'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.face_retouching_natural_rounded, size: 18),
            label: const Text('Perbarui'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );

    if (updateNow == true && mounted) {
      await _goToEnrollment();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          if (!_enrollChecked) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }
          if (!_isEnrolled) return _buildEnrollPrompt();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const reservedContentHeight = 232.0;
                  final maxCameraHeight =
                      constraints.maxHeight - reservedContentHeight;
                  final desiredCameraHeight = constraints.maxWidth * 1.24;
                  final rawCameraHeight = desiredCameraHeight < maxCameraHeight
                      ? desiredCameraHeight
                      : maxCameraHeight;
                  final targetCameraHeight = rawCameraHeight.clamp(
                    240.0,
                    452.0,
                  );

                  return Column(
                    children: [
                      SizedBox(
                        height: targetCameraHeight,
                        child: _buildCameraArea(),
                      ),
                      const SizedBox(height: 12),
                      _buildStatusSummary(),
                      const SizedBox(height: 10),
                      if (!_isCheckedOut && !kIsWeb)
                        _buildFaceDetectionStatus(),
                      const SizedBox(height: 14),
                      _buildActionButton(),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Face detection status ─────────────────────────────────────────────────

  Widget _buildFaceDetectionStatus() {
    final (icon, label, color, bg) = _faceDetectionStatusStyle();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String, Color, Color) _faceDetectionStatusStyle() {
    if (_processing) {
      return (
        Icons.hourglass_top_rounded,
        'Menyimpan presensi...',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_faceMatched) {
      return (
        Icons.verified_rounded,
        'Wajah cocok. Menyimpan presensi...',
        AppColors.success,
        AppColors.successLight,
      );
    }
    if (_checkingFace) {
      final sample = _verificationEmbeddings.length.clamp(
        0,
        _maxVerificationSamples,
      );
      return (
        Icons.manage_search_rounded,
        'Mengambil sampel wajah... ($sample/$_maxVerificationSamples)',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_matchFailed) {
      return (
        Icons.face_retouching_off_rounded,
        _lastSimilarity == null
            ? 'Wajah tidak mirip. Konfirmasi ulang lagi.'
            : 'Wajah tidak mirip. Konfirmasi ulang lagi (${(_lastSimilarity! * 100).toStringAsFixed(1)}%).',
        AppColors.error,
        AppColors.errorLight,
      );
    }
    return (
      Icons.face_rounded,
      'Tekan presensi -> arahkan wajah -> tahan posisi',
      AppColors.textSecondary,
      AppColors.background,
    );
  }

  // ── Enrollment prompt ─────────────────────────────────────────────────────

  Widget _buildEnrollPrompt() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.border),
          boxShadow: _softShadow(),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.12),
                ),
              ),
              child: const Icon(
                Icons.face_retouching_off_rounded,
                size: 38,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Wajah Belum Terdaftar',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Daftarkan wajah satu kali agar presensi bisa cocok dengan akun ini.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _goToEnrollment,
                icon: const Icon(
                  Icons.face_retouching_natural_rounded,
                  size: 20,
                ),
                label: const Text(
                  'Daftarkan Wajah Sekarang',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      toolbarHeight: 64,
      title: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.face_retouching_natural_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Absensi',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _todayLabel(),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
          child: Align(alignment: Alignment.center, child: _buildStatusBadge()),
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: AppColors.border),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final (label, color, bg) = _statusStyle();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color, Color) _statusStyle() {
    if (_isCheckedOut) {
      return ('Selesai', AppColors.success, AppColors.successLight);
    }
    if (_isCheckedIn) {
      return ('Sudah Check-In', AppColors.warning, AppColors.warningLight);
    }
    return ('Belum Hadir', AppColors.missing, AppColors.missingLight);
  }

  // ── Status summary ────────────────────────────────────────────────────────

  Widget _buildStatusSummary() {
    final record = _todayRecord;
    final cin = record?.checkIn;
    final cout = record?.checkOut;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: _softShadow(),
      ),
      child: Row(
        children: [
          Expanded(child: _timeSlot('Check-in', cin, AppColors.success)),
          const SizedBox(width: 10),
          Expanded(child: _timeSlot('Check-out', cout, AppColors.error)),
        ],
      ),
    );
  }

  Widget _timeSlot(String label, TimeOfDay? time, Color activeColor) {
    final hasTime = time != null;
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: hasTime
                ? activeColor.withValues(alpha: 0.08)
                : AppColors.background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hasTime
                  ? activeColor.withValues(alpha: 0.14)
                  : AppColors.border,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                hasTime ? _fmtTod(time) : '--:--',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: hasTime ? activeColor : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Camera area ───────────────────────────────────────────────────────────

  Widget _buildCameraArea() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
        boxShadow: _softShadow(),
      ),
      padding: const EdgeInsets.all(6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _isCheckedOut
            ? _buildCompletedAttendanceView()
            : CameraFaceView(
                key: _cameraKey,
                active: widget.isActive,
                hint: _verificationEmbeddings.isEmpty
                    ? 'Arahkan wajah dan tahan posisi'
                    : 'Tahan wajah tetap stabil',
                liveMode: false,
                enableLiveness: false,
                onTimeout: () {
                  if (!mounted) return;
                  _sampleAttempts++;
                  if (_sampleAttempts > 0 &&
                      _sampleAttempts < _maxVerificationCaptures &&
                      _verificationEmbeddings.length <
                          _maxVerificationSamples) {
                    unawaited(_scanNextFaceSample());
                    return;
                  }
                  _showFaceMatchFailed(
                    'Wajah tidak terdeteksi. Silakan konfirmasi ulang.',
                  );
                },
                onFaceDetected:
                    ({
                      required fullImage,
                      required inputImage,
                      required nv21Bytes,
                      required rawWidth,
                      required rawHeight,
                      required rotation,
                      required face,
                    }) => _onFaceDetectedForAttendance(
                      fullImage: fullImage,
                      nv21Bytes: nv21Bytes,
                      rawWidth: rawWidth,
                      rawHeight: rawHeight,
                      rotation: rotation,
                      face: face,
                    ),
              ),
      ),
    );
  }

  // ── Completed attendance view ─────────────────────────────────────────────

  Widget _buildCompletedAttendanceView() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.successLight,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.success.withValues(alpha: 0.16),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x120F172A),
                    blurRadius: 16,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                size: 36,
                color: AppColors.success,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _completedAttendanceHeadline(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _completedAttendanceMessage(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                _completedAttendanceFooter(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _completedAttendanceHeadline() {
    final hour = DateTime.now().hour;
    if (hour >= 17) return 'Sampai ketemu esok hari';
    if (hour >= 12) return 'Presensi hari ini sudah lengkap';
    return 'Presensi selesai dengan baik';
  }

  String _completedAttendanceMessage() {
    final checkIn = _todayRecord?.checkIn;
    final checkOut = _todayRecord?.checkOut;
    final checkInText = checkIn != null ? _fmtTod(checkIn) : '--:--';
    final checkOutText = checkOut != null ? _fmtTod(checkOut) : '--:--';
    return 'Check-in tercatat pukul $checkInText dan check-out pukul '
        '$checkOutText. Deteksi kamera untuk hari ini sudah selesai.';
  }

  String _completedAttendanceFooter() {
    final hour = DateTime.now().hour;
    if (hour >= 17) return 'Terima kasih, selamat beristirahat';
    if (hour >= 12) return 'Terima kasih, semoga harimu lancar';
    return 'Terima kasih, sampai jumpa lagi';
  }

  // ── Action button ─────────────────────────────────────────────────────────

  Widget _buildActionButton() {
    if (_isCheckedOut) {
      return SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.check_circle_rounded, size: 20),
          label: const Text(
            'Presensi Selesai',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.successLight,
            foregroundColor: AppColors.success,
            disabledBackgroundColor: AppColors.successLight,
            disabledForegroundColor: AppColors.success,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      );
    }

    if (kIsWeb) {
      return SizedBox(
        width: double.infinity,
        height: 56,
        child: ElevatedButton.icon(
          onPressed: _processing ? null : _handleButtonTap,
          icon: Icon(
            _isCheckedIn ? Icons.logout_rounded : Icons.login_rounded,
            size: 20,
          ),
          label: Text(
            _processing
                ? 'Memproses…'
                : (_isCheckedIn ? 'Check-Out Manual' : 'Check-In Manual'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _isCheckedIn ? AppColors.error : AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      );
    }

    final busy = _processing || _checkingFace;
    final label = _processing
        ? 'Memproses...'
        : (_checkingFace
              ? 'Menganalisis wajah...'
              : (_isCheckedIn
                    ? 'Konfirmasi Check-Out'
                    : 'Konfirmasi Check-In'));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: busy ? null : _handleButtonTap,
        icon: Icon(
          !_checkingFace
              ? (_isCheckedIn ? Icons.logout_rounded : Icons.login_rounded)
              : Icons.face_retouching_natural_rounded,
          size: 20,
        ),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isCheckedIn ? AppColors.error : AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.border,
          disabledForegroundColor: AppColors.textSecondary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  List<BoxShadow> _softShadow() => [
    BoxShadow(
      color: AppColors.primaryDark.withValues(alpha: 0.045),
      blurRadius: 16,
      offset: const Offset(0, 8),
    ),
  ];

  String _todayLabel() {
    final now = DateTime.now();
    const months = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    const days = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}';
  }

  Future<String?> _checkSamplesAgainstOtherRegisteredUsers(
    List<List<double>> embeddings,
  ) async {
    for (final embedding in embeddings) {
      final ownerId = await _checkForDuplicateFaceOwner(
        embedding,
        matchThreshold: _registeredOtherFaceRejectDistance,
      );
      if (ownerId != null) return ownerId;
    }
    return null;
  }

  Future<String?> _checkNearestRegisteredFaceOwner(
    List<List<double>> embeddings,
  ) async {
    String? nearestOwnerId;
    double nearestDistance = double.infinity;

    for (final embedding in embeddings) {
      final result = await _findNearestFaceOwner(embedding);
      if (result == null) continue;
      final (ownerId, distance) = result;
      if (distance < nearestDistance) {
        nearestOwnerId = ownerId;
        nearestDistance = distance;
      }
    }

    return nearestOwnerId;
  }

  Future<(String, double)?> _findNearestFaceOwner(
    List<double> embedding,
  ) async {
    final supabase = SupabaseClientService.client;
    try {
      final result = await supabase.rpc(
        'find_nearest_face_owner',
        params: {'query_embedding': jsonEncode(embedding)},
      );
      if (result is List && result.isNotEmpty) {
        final row = result.first;
        if (row is Map) {
          final ownerId = row['employee_id']?.toString();
          final distance = (row['distance'] as num?)?.toDouble();
          if (ownerId != null && distance != null) return (ownerId, distance);
        }
      }
    } on PostgrestException catch (e) {
      // Migration may not be installed yet. Keep local verification as the
      // source of truth until the Supabase RPC is applied.
      // ignore: avoid_print
      print('[Attendance] nearest-owner RPC unavailable: ${e.message}');
    }
    return null;
  }

  Future<String?> _checkForDuplicateFaceOwner(
    List<double> embedding, {
    double? matchThreshold,
  }) async {
    final threshold =
        matchThreshold ?? EmbeddingSyncService.duplicateFaceThreshold;
    final supabase = SupabaseClientService.client;
    final result = await supabase.rpc(
      'find_duplicate_face_owner',
      params: {
        'query_embedding': jsonEncode(embedding),
        'match_threshold': threshold,
      },
    );
    if (result is List && result.isNotEmpty) {
      for (final row in result) {
        if (row is Map) {
          final ownerId = row['employee_id']?.toString();
          final currentUid = AuthService.instance.currentUserId?.toString();
          if (ownerId != null && ownerId != currentUid) {
            return ownerId;
          }
        }
      }
    }
    return null;
  }
}
