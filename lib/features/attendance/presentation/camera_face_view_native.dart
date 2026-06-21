import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import '../../../shared/services/face/face_quality_filter.dart';
import '../../../shared/services/screen_brightness_service.dart';
import '../../../shared/theme/app_colors.dart';

enum CameraFaceState {
  loading,
  ready,
  scanning,
  detected,
  timeout,
  error,
  done,
}

/// Status pengenalan wajah secara live (dikirim tiap frame saat mode live).
enum LiveFaceDetectionStatus {
  noFace, // tidak ada wajah di frame
  detecting, // wajah ada dan sedang dideteksi
  recognized,
  uncertain,
  rejected,
}

class LiveFaceDetectionResult {
  final LiveFaceDetectionStatus status;
  final double similarity;
  final img.Image? fullImage;
  final InputImage? inputImage;
  final Uint8List? nv21Bytes;
  final int rawWidth;
  final int rawHeight;
  final InputImageRotation? rotation;
  final Face? face;
  final String? rejectReason;

  const LiveFaceDetectionResult({
    required this.status,
    this.similarity = 0,
    this.fullImage,
    this.inputImage,
    this.nv21Bytes,
    this.rawWidth = 0,
    this.rawHeight = 0,
    this.rotation,
    this.face,
    this.rejectReason,
  });
}

typedef FaceDetectedCallback =
    Future<bool> Function({
      required img.Image? fullImage,
      required InputImage inputImage,
      required Uint8List? nv21Bytes,
      required int rawWidth,
      required int rawHeight,
      required InputImageRotation rotation,
      required Face face,
    });

typedef LiveFaceDetectionCallback =
    void Function(LiveFaceDetectionResult result);

class CameraFaceView extends StatefulWidget {
  final bool active;
  final String hint;
  final FaceDetectedCallback? onFaceDetected;
  final VoidCallback? onTimeout;

  /// Saat [liveMode] = true, kamera langsung stream dan memanggil
  /// [onLiveFaceDetection] tiap ada frame yang terdeteksi wajah.
  /// Tombol scan / timeout tidak digunakan dalam mode ini.
  final bool liveMode;
  final LiveFaceDetectionCallback? onLiveFaceDetection;
  final bool enableLiveness;

  const CameraFaceView({
    super.key,
    this.active = true,
    this.hint = 'Arahkan wajah ke kamera',
    this.onFaceDetected,
    this.onTimeout,
    this.liveMode = false,
    this.onLiveFaceDetection,
    this.enableLiveness = true,
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
      enableClassification: true,
      enableContours: false,
      enableTracking: true,
    ),
  );

  Timer? _timeoutTimer;
  int _countdown = _timeoutSec;
  bool _scanning = false;
  bool _processingFrame = false;
  bool _disposed = false;
  bool _brightnessLocked = false;
  List<Face> _visibleFaces = const [];
  Size? _visibleImageSize;
  InputImageRotation? _visibleRotation;

  int _blinkCount = 0;
  bool _eyesPreviouslyClosed = false;
  bool _livenessPassed = false;
  int _stableFrameCount = 0;
  double? _lastYaw;
  double? _lastPitch;
  double? _lastRoll;

  static const int _timeoutSec = 10;
  static const bool _livenessEnabled = true;
  static const int _requiredBlinkCount = 1;
  static const int _stableFramesRequired = 3;
  static const double _maxYawDeltaPerFrame = 7.0;
  static const double _maxPitchDeltaPerFrame = 5.0;
  static const double _maxRollDeltaPerFrame = 5.0;

  // Live mode — throttle face detection agar tidak overload CPU.
  // 300ms memberi inference cukup waktu selesai sebelum frame berikutnya.
  static const Duration _liveThrottle = Duration(milliseconds: 300);
  static const Duration _faceOverlayThrottle = Duration(milliseconds: 200);
  static const Duration _statusUiThrottle = Duration(milliseconds: 200);
  DateTime _lastLiveProcess = DateTime(0);
  DateTime _lastFaceOverlayUpdate = DateTime(0);
  DateTime _lastStatusUiUpdate = DateTime(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) {
      _acquireBrightness();
      unawaited(_initCamera());
    } else {
      _state = CameraFaceState.ready;
    }
  }

  @override
  void didUpdateWidget(CameraFaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _acquireBrightness();
      if (_controller == null) unawaited(_initCamera());
      return;
    }
    if (!widget.active && oldWidget.active) {
      _releaseBrightness();
      unawaited(_releaseCamera());
      return;
    }
    if (!widget.active) {
      unawaited(_stopScan());
      return;
    }
    if (_controller == null && _state != CameraFaceState.loading) {
      unawaited(_initCamera());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _controller;
    if (state == AppLifecycleState.inactive) {
      _releaseBrightness();
      if (ctrl != null && ctrl.value.isInitialized) {
        unawaited(_disposeController(ctrl));
      }
    } else if (state == AppLifecycleState.resumed && widget.active) {
      _acquireBrightness();
      if (_controller == null) unawaited(_initCamera());
    }
  }

  void _acquireBrightness() {
    if (_brightnessLocked) return;
    _brightnessLocked = true;
    unawaited(ScreenBrightnessService.instance.acquireMax());
  }

  void _releaseBrightness() {
    if (!_brightnessLocked) return;
    _brightnessLocked = false;
    unawaited(ScreenBrightnessService.instance.releaseMax());
  }

  Future<void> _releaseCamera() async {
    await _stopScan();
    _clearVisibleFaces();
    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      try {
        await ctrl.dispose();
      } catch (_) {}
    }
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
    if (previous != null) await _disposeController(previous);

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

      // medium resolution: lighter frames → smoother preview while inferencing.
      final ctrl = CameraController(
        front,
        widget.liveMode ? ResolutionPreset.medium : ResolutionPreset.high,
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

      try {
        await ctrl.setExposureMode(ExposureMode.auto);
        await ctrl.setExposureOffset(0.0);
      } catch (_) {}
      try {
        await ctrl.setFocusMode(FocusMode.auto);
      } catch (_) {}

      setState(() => _state = CameraFaceState.ready);

      // Live mode: langsung mulai stream setelah kamera siap.
      if (widget.liveMode) {
        _resetLiveness();
        unawaited(_startLiveStream());
      }
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

  // ── Live mode stream ──────────────────────────────────────────────────────

  Future<void> _startLiveStream() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (ctrl.value.isStreamingImages) return;
    try {
      await ctrl.startImageStream(_onLiveFrame);
    } catch (_) {}
  }

  /// Public hook untuk parent menghentikan stream live tanpa men-dispose
  /// camera. Stream bisa di-resume lagi dengan [resetToReady].
  Future<void> pauseLiveStream() async {
    final ctrl = _controller;
    _processingFrame = false;
    _clearVisibleFaces();
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        !ctrl.value.isStreamingImages) {
      return;
    }
    try {
      await ctrl.stopImageStream();
    } catch (_) {}
  }

  Future<void> _onLiveFrame(CameraImage image) async {
    if (_processingFrame || _disposed) return;

    final now = DateTime.now();
    if (now.difference(_lastLiveProcess) < _liveThrottle) return;
    _lastLiveProcess = now;
    _processingFrame = true;

    try {
      // Copy raw bytes UP FRONT — camera plugin reuses plane buffers across
      // frames. If we hand the original buffer to MLKit (async) or pass it
      // upstream for later isolate decode, the next frame can corrupt it.
      // Cost: ~1 alloc + memcpy of one plane (~few hundred KB at medium res).
      final planeBytes = Uint8List.fromList(image.planes.first.bytes);
      final bytesPerRow = image.planes.first.bytesPerRow;
      final imgW = image.width;
      final imgH = image.height;

      final rotation = _currentRotation();
      if (rotation == null) {
        widget.onLiveFaceDetection?.call(
          const LiveFaceDetectionResult(status: LiveFaceDetectionStatus.noFace),
        );
        return;
      }

      final inputImage = InputImage.fromBytes(
        bytes: planeBytes,
        metadata: InputImageMetadata(
          size: Size(imgW.toDouble(), imgH.toDouble()),
          rotation: rotation,
          format: Platform.isAndroid
              ? InputImageFormat.nv21
              : InputImageFormat.bgra8888,
          bytesPerRow: bytesPerRow,
        ),
      );

      final faces = await _faceDetector.processImage(inputImage);
      // Defensive re-check after async gap — widget may have been disposed
      // or paused (e.g. parent triggered verification failure).
      if (!mounted || _disposed) return;
      final ctrl = _controller;
      if (ctrl == null || !ctrl.value.isStreamingImages) return;

      if (faces.isEmpty) {
        _updateVisibleFaces(const [], null, null);
        widget.onLiveFaceDetection?.call(
          const LiveFaceDetectionResult(status: LiveFaceDetectionStatus.noFace),
        );
        return;
      }

      _updateVisibleFaces(
        faces,
        Size(imgW.toDouble(), imgH.toDouble()),
        rotation,
      );

      final face = faces.first;

      // ── Liveness Detection (Blink tracking) ────────────────────────────────
      if (face.leftEyeOpenProbability != null &&
          face.rightEyeOpenProbability != null) {
        final leftOpen = face.leftEyeOpenProbability! > 0.5;
        final rightOpen = face.rightEyeOpenProbability! > 0.5;
        final bothClosed = !leftOpen && !rightOpen;

        if (bothClosed) {
          _eyesPreviouslyClosed = true;
        } else if (_eyesPreviouslyClosed && leftOpen && rightOpen) {
          // Both eyes were closed, now both are open = 1 blink.
          _blinkCount++;
          _eyesPreviouslyClosed = false;
          if (_blinkCount >= _requiredBlinkCount) {
            _livenessPassed = true;
          }
          _refreshStatusUi(force: true);
        }
      }

      // Fast check — hanya bounding box + tilt, tanpa decode pixel.
      final quality = FaceQualityFilter.evaluateFast(face, imgW, imgH);
      if (!quality.accepted) {
        widget.onLiveFaceDetection?.call(
          LiveFaceDetectionResult(
            status: LiveFaceDetectionStatus.rejected,
            face: face,
            rejectReason: quality.rejectReason,
          ),
        );
        return;
      }

      // Bytes sudah di-copy di atas — aman untuk dipass ke isolate.
      widget.onLiveFaceDetection?.call(
        LiveFaceDetectionResult(
          status: LiveFaceDetectionStatus.detecting,
          nv21Bytes: Platform.isAndroid ? planeBytes : null,
          rawWidth: imgW,
          rawHeight: imgH,
          rotation: rotation,
          face: face,
        ),
      );
    } catch (_) {
      // Abaikan error per-frame.
    } finally {
      _processingFrame = false;
    }
  }

  // ── Scan mode (button-triggered) ─────────────────────────────────────────

  bool startScan() {
    if (_scanning || _state == CameraFaceState.done) return false;
    if (_state != CameraFaceState.ready) return false;

    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return false;

    _scanning = true;
    _processingFrame = false;
    _countdown = _timeoutSec;
    _clearVisibleFaces();
    _resetLiveness();
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
    return true;
  }

  Future<void> _stopScan() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _scanning = false;
    _processingFrame = false;
    _clearVisibleFaces();

    final ctrl = _controller;
    if (ctrl != null &&
        ctrl.value.isInitialized &&
        ctrl.value.isStreamingImages) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {}
    }
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (!_scanning || _processingFrame) return;
    _processingFrame = true;

    try {
      final plane = image.planes.first;
      final nv21Bytes = Platform.isAndroid
          ? Uint8List.fromList(plane.bytes)
          : null;
      final inputImage = _buildInputImage(image, overrideBytes: nv21Bytes);
      final rotation = _currentRotation();
      if (inputImage == null || rotation == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (!_scanning || !mounted) return;
      if (faces.isEmpty) {
        _updateVisibleFaces(const [], null, null);
        return;
      }

      final face = faces.first;
      _updateVisibleFaces(
        faces,
        Size(image.width.toDouble(), image.height.toDouble()),
        rotation,
      );

      // ── Liveness Detection (Blink tracking) untuk Scan Mode ───────────────
      if (face.leftEyeOpenProbability != null &&
          face.rightEyeOpenProbability != null) {
        final leftOpen = face.leftEyeOpenProbability! > 0.5;
        final rightOpen = face.rightEyeOpenProbability! > 0.5;
        final bothClosed = !leftOpen && !rightOpen;

        if (bothClosed) {
          _eyesPreviouslyClosed = true;
        } else if (_eyesPreviouslyClosed && leftOpen && rightOpen) {
          _blinkCount++;
          _eyesPreviouslyClosed = false;
          if (_blinkCount >= _requiredBlinkCount) {
            _livenessPassed = true;
          }
          _refreshStatusUi(force: true);
        }
      }

      final quality = FaceQualityFilter.evaluateFast(
        face,
        image.width,
        image.height,
      );
      if (!quality.accepted) {
        _resetPoseStability();
        return;
      }

      if (widget.enableLiveness && _livenessEnabled && !_livenessPassed) {
        _refreshStatusUi();
        return;
      }

      if (!_isPoseStable(face)) {
        _refreshStatusUi();
        return;
      }

      final fullImage = _cameraImageToImage(image, rotation);
      if (fullImage == null) return;
      final best = _SampledFrame(
        fullImage: fullImage,
        inputImage: inputImage,
        nv21Bytes: nv21Bytes,
        rawWidth: image.width,
        rawHeight: image.height,
        rotation: rotation,
        face: face,
        qualityScore: quality.score,
      );

      try {
        final shouldStop =
            await widget.onFaceDetected?.call(
              fullImage: best.fullImage,
              inputImage: best.inputImage,
              nv21Bytes: best.nv21Bytes,
              rawWidth: best.rawWidth,
              rawHeight: best.rawHeight,
              rotation: best.rotation,
              face: best.face,
            ) ??
            false;
        if (!shouldStop) return;

        _scanning = false;
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        _clearVisibleFaces();
        unawaited(_stopScan());

        if (mounted && _state != CameraFaceState.done) {
          setState(() => _state = CameraFaceState.detected);
        }
      } catch (_) {
        if (mounted) resetToReady();
      }
    } catch (_) {
    } finally {
      _processingFrame = false;
    }
  }

  // ── Image helpers ─────────────────────────────────────────────────────────

  void _updateVisibleFaces(
    List<Face> faces,
    Size? imageSize,
    InputImageRotation? rotation,
  ) {
    if (!mounted || _disposed) return;
    if (faces.isEmpty &&
        _visibleFaces.isEmpty &&
        _visibleImageSize == null &&
        _visibleRotation == null) {
      return;
    }
    final now = DateTime.now();
    if (faces.isNotEmpty &&
        now.difference(_lastFaceOverlayUpdate) < _faceOverlayThrottle) {
      return;
    }
    _lastFaceOverlayUpdate = now;
    setState(() {
      _visibleFaces = List<Face>.unmodifiable(faces);
      _visibleImageSize = imageSize;
      _visibleRotation = rotation;
    });
  }

  void _refreshStatusUi({bool force = false}) {
    if (!mounted || _disposed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastStatusUiUpdate) < _statusUiThrottle) {
      return;
    }
    _lastStatusUiUpdate = now;
    setState(() {});
  }

  void _clearVisibleFaces() {
    if (_visibleFaces.isEmpty &&
        _visibleImageSize == null &&
        _visibleRotation == null) {
      return;
    }

    _visibleFaces = const [];
    _visibleImageSize = null;
    _visibleRotation = null;

    if (!mounted || _disposed) return;
    setState(() {});
  }

  InputImage? _buildInputImage(CameraImage image, {Uint8List? overrideBytes}) {
    final ctrl = _controller;
    if (ctrl == null) return null;

    final rotation = _rotationFromSensor(ctrl.description.sensorOrientation);
    if (rotation == null) return null;

    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormat.bgra8888;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: overrideBytes ?? plane.bytes,
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

  // ── State controls ────────────────────────────────────────────────────────

  void _resetLiveness() {
    _blinkCount = 0;
    _eyesPreviouslyClosed = false;
    _livenessPassed = false;
    _resetPoseStability();
  }

  bool _isPoseStable(Face face) {
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    final roll = face.headEulerAngleZ;
    if (yaw == null || pitch == null || roll == null) {
      _resetPoseStability();
      return false;
    }

    final stable =
        _lastYaw != null &&
        (yaw - _lastYaw!).abs() <= _maxYawDeltaPerFrame &&
        (pitch - _lastPitch!).abs() <= _maxPitchDeltaPerFrame &&
        (roll - _lastRoll!).abs() <= _maxRollDeltaPerFrame;

    _lastYaw = yaw;
    _lastPitch = pitch;
    _lastRoll = roll;
    _stableFrameCount = stable ? _stableFrameCount + 1 : 1;

    return _stableFrameCount >= _stableFramesRequired;
  }

  void _resetPoseStability() {
    _stableFrameCount = 0;
    _lastYaw = null;
    _lastPitch = null;
    _lastRoll = null;
  }

  String _timeoutTitle() {
    if (widget.enableLiveness &&
        _livenessEnabled &&
        _visibleFaces.isNotEmpty &&
        !_livenessPassed) {
      return 'Liveness belum terdeteksi';
    }
    return 'Wajah tidak terdeteksi';
  }

  String _timeoutMessage() {
    if (widget.enableLiveness &&
        _livenessEnabled &&
        _visibleFaces.isNotEmpty &&
        !_livenessPassed) {
      return 'Kedipkan mata saat kamera memindai\nlalu coba lagi';
    }
    return 'Pastikan wajah terlihat jelas\nlalu coba lagi';
  }

  void _onTimeout() {
    unawaited(_stopScan());
    _clearVisibleFaces();
    if (!mounted) return;
    setState(() => _state = CameraFaceState.timeout);
    widget.onTimeout?.call();
  }

  void resetToReady() {
    unawaited(_stopScan());
    if (!mounted) return;
    setState(() {
      _state = CameraFaceState.ready;
      _countdown = _timeoutSec;
    });
    _resetLiveness();
    _clearVisibleFaces();
    // Live mode: restart stream setelah reset.
    if (widget.liveMode) unawaited(_startLiveStream());
  }

  void markDone() {
    unawaited(_stopScan());
    _clearVisibleFaces();
    if (!mounted) return;
    setState(() => _state = CameraFaceState.done);
  }

  Future<void> refreshCamera() async {
    await _stopScan();
    _clearVisibleFaces();
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
    _clearVisibleFaces();
    if (_controller == ctrl) _controller = null;
    try {
      await ctrl.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopScan());
    WidgetsBinding.instance.removeObserver(this);
    _faceDetector.close();
    _controller?.dispose();
    _releaseBrightness();
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
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
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
              Text(
                _timeoutTitle(),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _timeoutMessage(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
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

      case CameraFaceState.done:
        return _placeholder(
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 40,
                color: AppColors.success,
              ),
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
      case CameraFaceState.detected:
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
        final isDetected = _state == CameraFaceState.detected;
        final trackedFaces = (widget.liveMode || isScanning)
            ? _visibleFaces
            : const <Face>[];
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: ctrl.value.previewSize!.height,
                    height: ctrl.value.previewSize!.width,
                    child: CameraPreview(ctrl),
                  ),
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _FaceFramePainter(
                    faces: trackedFaces,
                    imageSize: _visibleImageSize,
                    rotation: _visibleRotation,
                    isFrontCamera:
                        ctrl.description.lensDirection ==
                        CameraLensDirection.front,
                  ),
                ),
              ),
              if ((isScanning || isDetected) && !widget.liveMode)
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
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
                            isDetected
                                ? 'Wajah terdeteksi'
                                : '$_countdown detik',
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
                bottom: MediaQuery.of(context).padding.bottom + 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          widget.liveMode
                              ? (_livenessPassed
                                    ? Icons.verified_user_rounded
                                    : Icons.face_retouching_natural_rounded)
                              : (isScanning
                                    ? Icons.search_rounded
                                    : Icons.info_outline_rounded),
                          size: 13,
                          color: _livenessPassed
                              ? AppColors.success
                              : Colors.white70,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.liveMode
                              ? (!widget.enableLiveness
                                    ? 'Arahkan wajah'
                                    : _livenessPassed
                                    ? 'Liveness OK'
                                    : (_blinkCount == 0
                                          ? 'Kedipkan mata'
                                          : 'Kedipan: $_blinkCount / $_requiredBlinkCount'))
                              : (isDetected
                                    ? 'Mencocokkan wajah...'
                                    : (isScanning
                                          ? (!widget.enableLiveness
                                                ? 'Tahan wajah tetap stabil'
                                                : _livenessPassed
                                                ? 'Liveness OK'
                                                : (_blinkCount == 0
                                                      ? 'Kedipkan mata'
                                                      : 'Kedipan: $_blinkCount / $_requiredBlinkCount'))
                                          : widget.hint)),
                          style: TextStyle(
                            fontSize: 11,
                            color: _livenessPassed
                                ? AppColors.success
                                : Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _placeholder({
    required Widget child,
    Color bg = AppColors.background,
  }) {
    return Container(color: bg, alignment: Alignment.center, child: child);
  }
}

class _SampledFrame {
  final img.Image? fullImage;
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

class _FaceFramePainter extends CustomPainter {
  final List<Face> faces;
  final Size? imageSize;
  final InputImageRotation? rotation;
  final bool isFrontCamera;

  const _FaceFramePainter({
    required this.faces,
    required this.imageSize,
    required this.rotation,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rawSize = imageSize;
    if (rawSize == null || rawSize.width <= 0 || rawSize.height <= 0) return;
    if (faces.isEmpty) return;

    final sourceSize = _sourceSize(rawSize);
    final scale = math.max(
      size.width / sourceSize.width,
      size.height / sourceSize.height,
    );
    final dx = (size.width - sourceSize.width * scale) / 2;
    final dy = (size.height - sourceSize.height * scale) / 2;

    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final stroke = Paint()
      ..color = AppColors.success
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    for (final face in faces) {
      final rect = _mapRect(face.boundingBox, sourceSize, scale, dx, dy);
      final radius = Radius.circular(math.min(rect.width, rect.height) * 0.08);
      final rounded = RRect.fromRectAndRadius(rect, radius);
      canvas.drawRRect(rounded, shadow);
      canvas.drawRRect(rounded, stroke);
    }
  }

  Size _sourceSize(Size rawSize) {
    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      return Size(rawSize.height, rawSize.width);
    }
    return rawSize;
  }

  Rect _mapRect(Rect box, Size sourceSize, double scale, double dx, double dy) {
    final left = isFrontCamera ? sourceSize.width - box.right : box.left;
    final right = isFrontCamera ? sourceSize.width - box.left : box.right;
    return Rect.fromLTRB(
      left * scale + dx,
      box.top * scale + dy,
      right * scale + dx,
      box.bottom * scale + dy,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceFramePainter oldDelegate) {
    return oldDelegate.faces != faces ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.isFrontCamera != isFrontCamera;
  }
}
