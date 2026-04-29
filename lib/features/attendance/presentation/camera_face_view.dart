import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../../../shared/theme/app_colors.dart';

enum CameraFaceState { loading, ready, scanning, detected, timeout, error, done }

class CameraFaceView extends StatefulWidget {
  final bool active;
  final String hint;
  /// Called when a face is detected within the timeout window.
  final VoidCallback? onFaceDetected;
  /// Called when 10 seconds pass without detecting a face.
  final VoidCallback? onTimeout;

  const CameraFaceView({
    super.key,
    this.active = true,
    this.hint = 'Arahkan wajah ke kamera',
    this.onFaceDetected,
    this.onTimeout,
  });

  @override
  State<CameraFaceView> createState() => CameraFaceViewState();
}

class CameraFaceViewState extends State<CameraFaceView>
    with WidgetsBindingObserver {
  CameraController? _controller;
  CameraFaceState _state = CameraFaceState.loading;
  String? _errorMsg;

  Timer? _scanTimer;
  Timer? _timeoutTimer;
  int _countdown = 10;
  bool _scanning = false;

  static const _timeoutSec = 10;
  // Simulated face detection interval — replace with real ML kit if available.
  static const _scanIntervalMs = 400;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didUpdateWidget(CameraFaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _initCamera();
    if (!widget.active) _stopScan();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopScan();
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (!mounted) return;
    setState(() => _state = CameraFaceState.loading);

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setError('Tidak ada kamera yang tersedia');
        return;
      }

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
      if (!mounted) { ctrl.dispose(); return; }

      _controller = ctrl;
      setState(() => _state = CameraFaceState.ready);
    } catch (e) {
      if (!mounted) return;
      _setError(
        e.toString().contains('denied')
            ? 'Izin kamera ditolak. Aktifkan di pengaturan.'
            : 'Gagal membuka kamera',
      );
    }
  }

  void _setError(String msg) {
    setState(() {
      _state = CameraFaceState.error;
      _errorMsg = msg;
    });
  }

  // ── Scan lifecycle ────────────────────────────────────────────────────────

  void startScan() {
    if (_scanning || _state == CameraFaceState.done) return;
    if (_state != CameraFaceState.ready) return;
    _scanning = true;
    _countdown = _timeoutSec;
    setState(() => _state = CameraFaceState.scanning);

    // Countdown ticker (updates UI every second)
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        _onTimeout();
      }
    });

    // Simulated face-detection polling
    _scanTimer = Timer.periodic(
      const Duration(milliseconds: _scanIntervalMs),
      (_) => _checkForFace(),
    );
  }

  void _stopScan() {
    _scanTimer?.cancel();
    _timeoutTimer?.cancel();
    _scanTimer = null;
    _timeoutTimer = null;
    _scanning = false;
  }

  Future<void> _checkForFace() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || !_scanning) return;

    try {
      final image = await ctrl.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);
      final detector = FaceDetector(options: FaceDetectorOptions());
      final faces = await detector.processImage(inputImage);
      await detector.close();

      final detected = faces.isNotEmpty;
      if (detected && _scanning) {
        _stopScan();
        if (!mounted) return;
        setState(() => _state = CameraFaceState.detected);
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        widget.onFaceDetected?.call();
      }
    } catch (_) {}
  }

  void _onTimeout() {
    _stopScan();
    if (!mounted) return;
    setState(() => _state = CameraFaceState.timeout);
    widget.onTimeout?.call();
  }

  void resetToReady() {
    _stopScan();
    if (!mounted) return;
    setState(() {
      _state = CameraFaceState.ready;
      _countdown = _timeoutSec;
    });
  }

  void markDone() {
    _stopScan();
    if (!mounted) return;
    setState(() => _state = CameraFaceState.done);
  }

  @override
  void dispose() {
    _stopScan();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case CameraFaceState.loading:
        return _placeholder(
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.primary,
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Memulai kamera…',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        );

      case CameraFaceState.error:
        return _placeholder(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt_outlined, size: 36, color: AppColors.textSecondary),
              const SizedBox(height: 10),
              Text(
                _errorMsg ?? 'Kamera tidak tersedia',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: _initCamera,
                child: const Text(
                  'Coba Lagi',
                  style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );

      case CameraFaceState.timeout:
        return _placeholder(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.errorLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.face_retouching_off_rounded, size: 36, color: AppColors.error),
              ),
              const SizedBox(height: 14),
              const Text(
                'Wajah tidak terdeteksi',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              const Text(
                'Pastikan wajah terlihat jelas\nlalu coba lagi',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: resetToReady,
                child: const Text(
                  'Coba Lagi',
                  style: TextStyle(fontSize: 13, color: AppColors.primary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );

      case CameraFaceState.detected:
        return _placeholder(
          bg: AppColors.successLight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded, size: 36, color: Colors.white),
              ),
              const SizedBox(height: 14),
              const Text(
                'Wajah Terdeteksi!',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.success),
              ),
            ],
          ),
        );

      case CameraFaceState.done:
        return _placeholder(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.check_circle_rounded, size: 40, color: AppColors.success),
              SizedBox(height: 10),
              Text(
                'Presensi selesai',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.success),
              ),
            ],
          ),
        );

      case CameraFaceState.ready:
      case CameraFaceState.scanning:
        final ctrl = _controller!;
        final isScanning = _state == CameraFaceState.scanning;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: ctrl.value.previewSize!.height,
                height: ctrl.value.previewSize!.width,
                child: CameraPreview(ctrl),
              ),
            ),
            // Oval overlay — green border while scanning
            CustomPaint(
              painter: _FaceOverlayPainter(
                scanning: isScanning,
                pulse: isScanning,
              ),
            ),
            // Countdown while scanning
            if (isScanning)
              Positioned(
                top: 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.timer_outlined, size: 13, color: Colors.white70),
                        const SizedBox(width: 5),
                        Text(
                          '$_countdown detik',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Hint chip at the bottom
            Positioned(
              bottom: 14,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isScanning ? Icons.search_rounded : Icons.info_outline_rounded,
                        size: 13,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isScanning ? 'Mendeteksi wajah…' : widget.hint,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
    }
  }

  Widget _placeholder({required Widget child, Color bg = AppColors.background}) {
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: child,
    );
  }
}

// ── Oval overlay painter ────────────────────────────────────────────────────

class _FaceOverlayPainter extends CustomPainter {
  final bool scanning;
  final bool pulse;

  const _FaceOverlayPainter({this.scanning = false, this.pulse = false});

  @override
  void paint(Canvas canvas, Size size) {
    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.62,
      height: size.height * 0.72,
    );

    // Dark mask outside oval
    final maskPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(maskPath, Paint()..color = Colors.black.withValues(alpha: 0.45));

    // Oval border — blue idle, primary while scanning
    final borderColor = scanning
        ? AppColors.primary.withValues(alpha: 0.95)
        : AppColors.primary.withValues(alpha: 0.9);
    _drawDashedOval(
      canvas,
      ovalRect,
      Paint()
        ..color = borderColor
        ..strokeWidth = scanning ? 2.5 : 2
        ..style = PaintingStyle.stroke,
    );

    // Corner brackets
    final bracketPaint = Paint()
      ..color = scanning ? AppColors.primary : AppColors.primary
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const len = 18.0;
    final outer = ovalRect.inflate(8);
    _bracket(canvas, bracketPaint, outer.topLeft, 1, 1, len);
    _bracket(canvas, bracketPaint, outer.topRight, -1, 1, len);
    _bracket(canvas, bracketPaint, outer.bottomLeft, 1, -1, len);
    _bracket(canvas, bracketPaint, outer.bottomRight, -1, -1, len);
  }

  void _bracket(Canvas canvas, Paint paint, Offset corner, double dx, double dy, double len) {
    canvas.drawLine(corner, corner + Offset(len * dx, 0), paint);
    canvas.drawLine(corner, corner + Offset(0, len * dy), paint);
  }

  void _drawDashedOval(Canvas canvas, Rect rect, Paint paint) {
    final path = Path()..addOval(rect);
    const dashLen = 7.0;
    const gapLen = 5.0;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + dashLen), paint);
        d += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FaceOverlayPainter old) =>
      old.scanning != scanning || old.pulse != pulse;
}
