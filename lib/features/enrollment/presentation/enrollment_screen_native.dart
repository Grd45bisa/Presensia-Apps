import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/face/face_recognition_service.dart';
import '../../../shared/services/screen_brightness_service.dart';
import '../../../shared/services/face/face_quality_filter.dart';
import '../../../shared/services/face/embedding_sync_service.dart';
import '../../../shared/theme/app_colors.dart';

enum _EnrollStep { front, left, right, processing, done, error }

class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen>
    with WidgetsBindingObserver {
  CameraController? _camCtrl;
  _EnrollStep _step = _EnrollStep.front;
  String? _errorMsg;

  // One best-quality embedding per pose (front / left / right).
  final List<List<double>> _embeddings = [];

  // Per-pose capture progress shown in the UI while sampling frames.
  int _sampledFrames = 0;
  int _acceptedFrames = 0;
  static const int _targetFrames = 5; // frames to attempt per pose

  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
    ),
  );

  bool _capturing = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenBrightnessService.instance.setMax();
    _initCamera();
    FaceRecognitionService.instance.init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _camCtrl?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty || !mounted || _disposed) return;

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final ctrl = CameraController(
      front,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await ctrl.initialize();
    if (!mounted || _disposed) {
      ctrl.dispose();
      return;
    }

    // Paksa brightness maksimum saat enrollment agar wajah selalu terang,
    // termasuk di ruangan gelap. Gunakan exposure offset maksimum yg diizinkan.
    try {
      final maxExp = await ctrl.getMaxExposureOffset();
      await ctrl.setExposureOffset(maxExp.clamp(0.0, 2.0));
    } catch (_) {
      // Abaikan — tidak semua device mendukung manual exposure.
    }

    setState(() => _camCtrl = ctrl);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _detector.close();
    _camCtrl?.dispose();
    FaceRecognitionService.instance.dispose();
    ScreenBrightnessService.instance.restore();
    super.dispose();
  }

  // ── Multi-frame capture ───────────────────────────────────────────────────

  /// Tap "Ambil Foto" → kumpulkan hingga [_targetFrames] kandidat foto,
  /// filter kualitas tiap frame, simpan embedding dengan skor tertinggi.
  Future<void> _capture() async {
    if (_capturing || _camCtrl == null) return;
    setState(() {
      _capturing = true;
      _sampledFrames = 0;
      _acceptedFrames = 0;
    });

    List<double>? bestEmbedding;
    double bestScore = -1;
    String? lastRejectReason;

    for (int attempt = 0; attempt < _targetFrames; attempt++) {
      if (!mounted || _disposed) break;

      // Jeda singkat agar frame berbeda satu sama lain (30 ms cukup).
      await Future.delayed(const Duration(milliseconds: 30));

      try {
        final xFile = await _camCtrl!.takePicture();
        final bytes = await File(xFile.path).readAsBytes();
        final fullImage = img.decodeImage(bytes);
        if (fullImage == null) continue;

        final inputImage = InputImage.fromFilePath(xFile.path);
        final faces = await _detector.processImage(inputImage);

        if (mounted) setState(() => _sampledFrames = attempt + 1);

        if (faces.isEmpty) {
          lastRejectReason = 'Wajah tidak terdeteksi';
          continue;
        }

        final face = faces.first;

        // Quality gate
        final quality = FaceQualityFilter.evaluate(fullImage, face);
        if (!quality.accepted) {
          lastRejectReason = quality.rejectReason;
          continue;
        }

        // Extract embedding
        final embedding = await FaceRecognitionService.instance
            .extractEmbedding(fullImage, face);
        if (embedding == null) continue;

        if (mounted) setState(() => _acceptedFrames++);

        // Keep only the best-scoring frame per pose
        if (quality.score > bestScore) {
          bestScore = quality.score;
          bestEmbedding = embedding;
        }
      } catch (_) {
        continue;
      }
    }

    if (!mounted || _disposed) return;

    if (bestEmbedding == null) {
      _showSnack(
        lastRejectReason != null
            ? 'Gagal: $lastRejectReason. Coba lagi dengan pencahayaan lebih baik.'
            : 'Tidak ada frame yang cukup berkualitas. Coba lagi.',
      );
      setState(() => _capturing = false);
      return;
    }

    _embeddings.add(bestEmbedding);

    if (_step == _EnrollStep.front) {
      setState(() {
        _step = _EnrollStep.left;
        _capturing = false;
        _sampledFrames = 0;
        _acceptedFrames = 0;
      });
    } else if (_step == _EnrollStep.left) {
      setState(() {
        _step = _EnrollStep.right;
        _capturing = false;
        _sampledFrames = 0;
        _acceptedFrames = 0;
      });
    } else if (_step == _EnrollStep.right) {
      await _finalize();
    }
  }

  Future<void> _finalize() async {
    if (!mounted) return;
    setState(() {
      _step = _EnrollStep.processing;
      _capturing = false;
    });

    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) throw Exception('Sesi tidak ditemukan');

      // Simpan 3 embedding terbaik (depan / kiri / kanan) secara terpisah.
      // Saat absensi, query dicocokkan ke embedding terbaik di antara ketiganya.
      await EmbeddingSyncService.instance.saveEmbeddings(uid, _embeddings);

      if (!mounted) return;
      setState(() => _step = _EnrollStep.done);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = 'Gagal menyimpan data wajah: ${e.toString()}';
        _step = _EnrollStep.error;
      });
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.warning,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _restart() {
    setState(() {
      _step = _EnrollStep.front;
      _errorMsg = null;
      _embeddings.clear();
      _capturing = false;
      _sampledFrames = 0;
      _acceptedFrames = 0;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Daftarkan Wajah',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.border),
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _EnrollStep.processing:
        return _buildProcessing();
      case _EnrollStep.done:
        return _buildDone();
      case _EnrollStep.error:
        return _buildError();
      default:
        return _buildCaptureStep();
    }
  }

  Widget _buildCaptureStep() {
    return Column(
      children: [
        _buildStepIndicator(),
        const SizedBox(height: 16),
        _buildInstruction(),
        const SizedBox(height: 12),
        Expanded(child: _buildCameraPreview()),
        const SizedBox(height: 12),
        if (_capturing) _buildSamplingProgress(),
        const SizedBox(height: 8),
        _buildCaptureButton(),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── Step indicator ────────────────────────────────────────────────────────

  Widget _buildStepIndicator() {
    final steps = [
      ('Depan', _EnrollStep.front),
      ('Kiri', _EnrollStep.left),
      ('Kanan', _EnrollStep.right),
    ];
    final currentIndex = steps.indexWhere((s) => s.$2 == _step);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: List.generate(steps.length * 2 - 1, (i) {
          if (i.isOdd) {
            return Expanded(
              child: Container(
                height: 2,
                color: i ~/ 2 < currentIndex
                    ? AppColors.primary
                    : AppColors.border,
              ),
            );
          }
          final idx = i ~/ 2;
          final isDone = idx < currentIndex;
          final isActive = idx == currentIndex;
          return Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? AppColors.success
                      : isActive
                          ? AppColors.primary
                          : AppColors.border,
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check_rounded,
                          size: 16, color: Colors.white)
                      : Text(
                          '${idx + 1}',
                          style: TextStyle(
                            color: isActive
                                ? Colors.white
                                : AppColors.textSecondary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                steps[idx].$1,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      isActive ? FontWeight.w700 : FontWeight.normal,
                  color: isActive
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  // ── Instruction card ──────────────────────────────────────────────────────

  Widget _buildInstruction() {
    final (title, subtitle, icon) = switch (_step) {
      _EnrollStep.front => (
          'Hadapkan wajah ke kamera',
          'Pastikan wajah Anda menghadap lurus ke kamera',
          Icons.face_rounded,
        ),
      _EnrollStep.left => (
          'Miringkan kepala ke kiri',
          'Putar kepala sekitar 30° ke arah kiri',
          Icons.rotate_left_rounded,
        ),
      _EnrollStep.right => (
          'Miringkan kepala ke kanan',
          'Putar kepala sekitar 30° ke arah kanan',
          Icons.rotate_right_rounded,
        ),
      _ => ('', '', Icons.face_rounded),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primaryLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sampling progress ─────────────────────────────────────────────────────

  Widget _buildSamplingProgress() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Menganalisis frame $_sampledFrames/$_targetFrames…',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                '$_acceptedFrames diterima',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _targetFrames > 0 ? _sampledFrames / _targetFrames : 0,
              backgroundColor: AppColors.border,
              color: AppColors.primary,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  // ── Camera preview ────────────────────────────────────────────────────────

  Widget _buildCameraPreview() {
    final ctrl = _camCtrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: ctrl.value.previewSize!.height,
                height: ctrl.value.previewSize!.width,
                child: CameraPreview(ctrl),
              ),
            ),
            CustomPaint(painter: _EnrollOverlayPainter()),
          ],
        ),
      ),
    );
  }

  // ── Capture button ────────────────────────────────────────────────────────

  Widget _buildCaptureButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          onPressed: _capturing ? null : _capture,
          icon: _capturing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.camera_alt_rounded, size: 20),
          label: Text(
            _capturing ? 'Mengambil sampel…' : 'Ambil Foto',
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }

  // ── Processing / Done / Error ─────────────────────────────────────────────

  Widget _buildProcessing() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.primary),
          SizedBox(height: 20),
          Text(
            'Menyimpan data wajah…',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDone() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: AppColors.successLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.verified_user_rounded,
                size: 52,
                color: AppColors.success,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Wajah Berhasil Didaftarkan!',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Data wajah Anda telah disimpan dengan aman.\nAnda sekarang dapat menggunakan absensi wajah.',
              style: TextStyle(
                  fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Selesai',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: AppColors.errorLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 52,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Pendaftaran Gagal',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMsg ?? 'Terjadi kesalahan.',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _restart,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Coba Lagi',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Oval overlay for enrollment ───────────────────────────────────────────────

class _EnrollOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.62,
      height: size.height * 0.72,
    );

    final maskPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
        maskPath, Paint()..color = Colors.black.withValues(alpha: 0.5));

    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = AppColors.primary
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
