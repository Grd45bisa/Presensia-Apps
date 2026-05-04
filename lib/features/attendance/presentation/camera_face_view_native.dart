import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import '../../../shared/services/face/face_quality_filter.dart';
import '../../../shared/services/screen_brightness_service.dart';
import '../../../shared/theme/app_colors.dart';

enum CameraFaceState { loading, ready, scanning, detected, timeout, error, done }

typedef FaceDetectedCallback = Future<void> Function({
  required img.Image fullImage,
  required InputImage inputImage,
  required Uint8List? nv21Bytes,
  required int rawWidth,
  required int rawHeight,
  required InputImageRotation rotation,
  required Face face,
});

class CameraFaceView extends StatefulWidget {
  final bool active;
  final String hint;
  final FaceDetectedCallback? onFaceDetected;
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

  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: true,
      enableClassification: false,
      enableContours: false,
      enableTracking: false,
    ),
  );

  Timer? _timeoutTimer;
  int _countdown = _timeoutSec;
  bool _scanning = false;
  bool _processingFrame = false;
  bool _disposed = false;

  // Multi-frame sampling — kumpulkan hingga _maxSampleFrames frame yang
  // terdeteksi wajah, evaluasi kualitasnya, kirim frame terbaik ke recognition.
  // Ini menghindari frame blur/gelap acak yang langsung dikirim.
  _SampledFrame? _bestFrame;
  int _sampledCount = 0;
  static const int _maxSampleFrames = 5;
  static const int _timeoutSec = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Hanya init kamera bila widget aktif. Saat MainScreen masih di tab lain,
    // AttendanceScreen di IndexedStack akan tetap di-build tapi isActive=false,
    // jadi kamera TIDAK boot lebih awal.
    if (widget.active) {
      unawaited(_initCamera());
    } else {
      _state = CameraFaceState.ready;
    }
  }

  @override
  void didUpdateWidget(CameraFaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tab Absensi baru saja menjadi aktif → boot kamera bila belum ada.
    if (widget.active && !oldWidget.active) {
      if (_controller == null) {
        unawaited(_initCamera());
      }
      return;
    }
    // Tab Absensi baru saja ditinggalkan → matikan stream + lepas controller.
    if (!widget.active && oldWidget.active) {
      unawaited(_releaseCamera());
      return;
    }
    // Tetap tidak aktif — pastikan tidak ada scan yang jalan.
    if (!widget.active) {
      unawaited(_stopScan());
      return;
    }
    // Tetap aktif — kalau controller hilang (mis. setelah resume), re-init.
    if (_controller == null && _state != CameraFaceState.loading) {
      unawaited(_initCamera());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;

    if (state == AppLifecycleState.inactive) {
      if (ctrl != null && ctrl.value.isInitialized) {
        unawaited(_disposeController(ctrl));
      }
    } else if (state == AppLifecycleState.resumed && widget.active) {
      if (_controller == null) {
        unawaited(_initCamera());
      }
    }
  }

  /// Hentikan stream, dispose controller, dan kembalikan state ke ready
  /// agar saat user balik ke tab ini, init bersih dari nol.
  Future<void> _releaseCamera() async {
    await _stopScan();
    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      try {
        await ctrl.dispose();
      } catch (_) {}
    }
    // Kembalikan kecerahan layar ke nilai semula saat kamera dilepas.
    await ScreenBrightnessService.instance.restore();
    if (!mounted || _disposed) return;
    setState(() {
      _state = CameraFaceState.ready;
      _countdown = _timeoutSec;
      _errorMsg = null;
    });
  }

  Future<void> _initCamera() async {
    if (!mounted || _disposed || !widget.active) return;
    setState(() => _state = CameraFaceState.loading);

    final previous = _controller;
    _controller = null;
    if (previous != null) {
      await _disposeController(previous);
    }

    try {
      final cameras = await availableCameras();
      if (!mounted || _disposed) return;

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
        // high agar resolusi setara dengan enrollment (yang juga pakai high),
        // sehingga embedding dari attendance dan enrollment berasal dari
        // kualitas gambar yang konsisten.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await ctrl.initialize();
      if (!mounted || _disposed) {
        await ctrl.dispose();
        return;
      }

      _controller = ctrl;

      // Paksa exposure kamera ke maksimum
      try {
        final maxExp = await ctrl.getMaxExposureOffset();
        await ctrl.setExposureOffset(maxExp.clamp(0.0, 2.0));
      } catch (_) {}

      // Paksa kecerahan layar ke 100% agar wajah terlihat jelas
      await ScreenBrightnessService.instance.setMax();

      setState(() => _state = CameraFaceState.ready);
    } catch (e) {
      if (!mounted || _disposed) return;
      _setError(
        e.toString().contains('denied')
            ? 'Izin kamera ditolak. Aktifkan di pengaturan.'
            : 'Gagal membuka kamera',
      );
    }
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _state = CameraFaceState.error;
      _errorMsg = msg;
    });
  }

  void startScan() {
    if (_scanning || _state == CameraFaceState.done) return;
    if (_state != CameraFaceState.ready) return;

    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    _scanning = true;
    _processingFrame = false;
    _countdown = _timeoutSec;
    _bestFrame = null;
    _sampledCount = 0;
    setState(() => _state = CameraFaceState.scanning);

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        timer.cancel();
        _onTimeout();
      }
    });

    unawaited(ctrl.startImageStream(_onCameraFrame));
  }

  Future<void> _stopScan() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _scanning = false;
    _processingFrame = false;

    final ctrl = _controller;
    if (ctrl != null && ctrl.value.isInitialized && ctrl.value.isStreamingImages) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {
        // Ignore stream shutdown races.
      }
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (!_scanning || _processingFrame) return;
    _processingFrame = true;

    try {
      final inputImage = _buildInputImage(image);
      final rotation = _currentRotation();
      if (inputImage == null || rotation == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (!_scanning || !mounted) return;
      if (faces.isEmpty) return;

      final fullImage = _cameraImageToImage(image, rotation);
      if (fullImage == null) return;

      // Quality check — hanya simpan frame jika lolos filter.
      final quality = FaceQualityFilter.evaluate(fullImage, faces.first);
      if (quality.accepted) {
        _sampledCount++;
        // Simpan frame dengan quality score tertinggi.
        final current = _bestFrame;
        if (current == null || quality.score > current.qualityScore) {
          _bestFrame = _SampledFrame(
            fullImage: fullImage,
            inputImage: inputImage,
            nv21Bytes: Platform.isAndroid ? image.planes.first.bytes : null,
            rawWidth: image.width,
            rawHeight: image.height,
            rotation: rotation,
            face: faces.first,
            qualityScore: quality.score,
          );
        }
      }

      // Lanjut sampling sampai dapat _maxSampleFrames frame yang diterima,
      // atau langsung kirim jika dapat frame berkualitas sangat baik (>0.85).
      final best = _bestFrame;
      final shouldDispatch = best != null &&
          (_sampledCount >= _maxSampleFrames || best.qualityScore > 0.85);

      if (!shouldDispatch) return;

      // Sudah dapat frame terbaik — stop stream dan kirim ke recognition.
      _scanning = false;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      unawaited(_stopScan());

      if (mounted) setState(() => _state = CameraFaceState.detected);

      try {
        await widget.onFaceDetected?.call(
          fullImage: best.fullImage,
          inputImage: best.inputImage,
          nv21Bytes: best.nv21Bytes,
          rawWidth: best.rawWidth,
          rawHeight: best.rawHeight,
          rotation: best.rotation,
          face: best.face,
        );
      } catch (_) {
        if (mounted) resetToReady();
      }
    } catch (_) {
      // Ignore per-frame errors.
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final ctrl = _controller;
    if (ctrl == null) return null;

    final rotation = _rotationFromSensor(ctrl.description.sensorOrientation);
    if (rotation == null) return null;

    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _currentRotation() {
    final ctrl = _controller;
    if (ctrl == null) return null;
    return _rotationFromSensor(ctrl.description.sensorOrientation);
  }

  InputImageRotation? _rotationFromSensor(int sensorOrientation) {
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }

    int rotationCompensation = sensorOrientation;
    final deviceOrientation = _controller?.value.deviceOrientation;
    if (deviceOrientation != null) {
      late final int deviceRot;
      switch (deviceOrientation) {
        case DeviceOrientation.portraitUp:
          deviceRot = 0;
        case DeviceOrientation.landscapeLeft:
          deviceRot = 90;
        case DeviceOrientation.portraitDown:
          deviceRot = 180;
        case DeviceOrientation.landscapeRight:
          deviceRot = 270;
      }

      if (_controller!.description.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + deviceRot) % 360;
      } else {
        rotationCompensation = (sensorOrientation - deviceRot + 360) % 360;
      }
    }

    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  img.Image? _cameraImageToImage(
    CameraImage image,
    InputImageRotation rotation,
  ) {
    try {
      if (Platform.isAndroid) {
        return _buildPreviewImageFromNv21(
          image.planes.first.bytes,
          image.width,
          image.height,
          rotation,
        );
      }

      return img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: image.planes.first.bytes.buffer,
        format: img.Format.uint8,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
    } catch (_) {
      return null;
    }
  }

  img.Image _buildPreviewImageFromNv21(
    Uint8List nv21,
    int width,
    int height,
    InputImageRotation rotation,
  ) {
    final image = img.Image(width: width, height: height);
    final ySize = width * height;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * width + x;
        final uvIndex = ySize + (y >> 1) * width + (x & ~1);

        final yVal = nv21[yIndex];
        final vVal = nv21[uvIndex];
        final uVal = nv21[uvIndex + 1];

        final r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        final g = (yVal - 0.698001 * (vVal - 128) - 0.337633 * (uVal - 128))
            .round()
            .clamp(0, 255);
        final b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);

        image.setPixelRgb(x, y, r, g, b);
      }
    }

    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return img.copyRotate(image, angle: 90);
      case InputImageRotation.rotation180deg:
        return img.copyRotate(image, angle: 180);
      case InputImageRotation.rotation270deg:
        return img.copyRotate(image, angle: 270);
      case InputImageRotation.rotation0deg:
        return image;
    }
  }

  void _onTimeout() {
    unawaited(_stopScan());
    if (!mounted) return;
    setState(() => _state = CameraFaceState.timeout);
    widget.onTimeout?.call();
  }

  void resetToReady() {
    unawaited(_stopScan());
    _bestFrame = null;
    _sampledCount = 0;
    if (!mounted) return;
    setState(() {
      _state = CameraFaceState.ready;
      _countdown = _timeoutSec;
    });
  }

  void markDone() {
    unawaited(_stopScan());
    if (!mounted) return;
    setState(() => _state = CameraFaceState.done);
  }

  Future<void> refreshCamera() async {
    await _stopScan();
    final ctrl = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _state = CameraFaceState.loading;
        _errorMsg = null;
        _countdown = _timeoutSec;
      });
    }
    await ctrl?.dispose();
    if (!mounted || _disposed || !widget.active) return;
    await _initCamera();
  }

  Future<void> _disposeController(CameraController ctrl) async {
    await _stopScan();
    if (_controller == ctrl) {
      _controller = null;
    }
    try {
      await ctrl.dispose();
    } catch (_) {
      // Ignore disposal races.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopScan());
    WidgetsBinding.instance.removeObserver(this);
    _faceDetector.close();
    _controller?.dispose();
    unawaited(ScreenBrightnessService.instance.restore());
    super.dispose();
  }

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
                'Memulai kamera...',
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
              const Icon(
                Icons.camera_alt_outlined,
                size: 36,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 10),
              Text(
                _errorMsg ?? 'Kamera tidak tersedia',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => unawaited(_initCamera()),
                child: const Text(
                  'Coba Lagi',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
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
                decoration: const BoxDecoration(
                  color: AppColors.errorLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.face_retouching_off_rounded,
                  size: 36,
                  color: AppColors.error,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Wajah tidak terdeteksi',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
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
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );

      case CameraFaceState.detected:
        return _placeholder(
          bg: AppColors.successLight,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primary),
              SizedBox(height: 14),
              Text(
                'Memverifikasi identitas...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        );

      case CameraFaceState.done:
        return _placeholder(
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_rounded, size: 40, color: AppColors.success),
              SizedBox(height: 10),
              Text(
                'Presensi selesai',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
        );

      case CameraFaceState.ready:
      case CameraFaceState.scanning:
        final ctrl = _controller;
        if (ctrl == null || !ctrl.value.isInitialized || _disposed) {
          return _placeholder(
            child: const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primary,
              ),
            ),
          );
        }

        final isScanning = _state == CameraFaceState.scanning;
        return Stack(
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
            CustomPaint(painter: _FaceOverlayPainter(scanning: isScanning)),
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
                        const Icon(
                          Icons.timer_outlined,
                          size: 13,
                          color: Colors.white70,
                        ),
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
                        isScanning ? 'Mendeteksi wajah...' : widget.hint,
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

class _FaceOverlayPainter extends CustomPainter {
  final bool scanning;

  const _FaceOverlayPainter({this.scanning = false});

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
    canvas.drawPath(maskPath, Paint()..color = Colors.black.withValues(alpha: 0.45));

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

    final bracketPaint = Paint()
      ..color = AppColors.primary
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

  void _bracket(
    Canvas canvas,
    Paint paint,
    Offset corner,
    double dx,
    double dy,
    double len,
  ) {
    canvas.drawLine(corner, corner + Offset(len * dx, 0), paint);
    canvas.drawLine(corner, corner + Offset(0, len * dy), paint);
  }

  void _drawDashedOval(Canvas canvas, Rect rect, Paint paint) {
    final path = Path()..addOval(rect);
    const dashLen = 7.0;
    const gapLen = 5.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dashLen), paint);
        distance += dashLen + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FaceOverlayPainter oldDelegate) {
    return oldDelegate.scanning != scanning;
  }
}

/// Data holder untuk satu frame kandidat yang sudah lolos quality filter.
/// Menyimpan semua data yang dibutuhkan oleh onFaceDetected callback.
class _SampledFrame {
  final img.Image fullImage;
  final InputImage inputImage;
  final Uint8List? nv21Bytes;
  final int rawWidth;
  final int rawHeight;
  final InputImageRotation rotation;
  final Face face;
  final double qualityScore;

  const _SampledFrame({
    required this.fullImage,
    required this.inputImage,
    required this.nv21Bytes,
    required this.rawWidth,
    required this.rawHeight,
    required this.rotation,
    required this.face,
    required this.qualityScore,
  });
}
