import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../../../shared/services/auth_service.dart';
import '../../../shared/services/face/embedding_sync_service.dart';
import '../../../shared/services/face/face_quality_filter.dart';
import '../../../shared/services/face/face_recognition_service.dart';
import '../../../shared/services/screen_brightness_service.dart';
import '../../../shared/theme/app_colors.dart';

enum _EnrollStep { capture, processing, done, error }

enum _EnrollStage { center, left, right, blink }

enum _ScanStatus { ready, scanning }

class _StageDef {
  const _StageDef(this.label, this.subtitle, this.icon);

  final String label;
  final String subtitle;
  final IconData icon;
}

class _FrameCandidate {
  const _FrameCandidate({
    required this.nv21Bytes,
    required this.rawWidth,
    required this.rawHeight,
    required this.rotation,
    required this.face,
    required this.faceCrop,
    required this.qualityScore,
    required this.featureScore,
  });

  final Uint8List nv21Bytes;
  final int rawWidth;
  final int rawHeight;
  final InputImageRotation rotation;
  final Face face;
  final img.Image faceCrop;
  final double qualityScore;
  final double featureScore;

  double get trainingScore =>
      (qualityScore * 0.65 + featureScore * 0.35).clamp(0.0, 1.0);
}

class _FeatureCheckResult {
  const _FeatureCheckResult({
    required this.accepted,
    required this.score,
    this.rejectReason,
  });

  final bool accepted;
  final double score;
  final String? rejectReason;
}

const Map<_EnrollStage, _StageDef> _stageDefs = {
  _EnrollStage.center: _StageDef(
    'Tatap lurus',
    'Hadapkan wajah tepat ke kamera. Sistem akan mengambil sampel otomatis.',
    Icons.face_rounded,
  ),
  _EnrollStage.left: _StageDef(
    'Tengok kiri sedikit',
    'Putar kepala sedikit ke kiri, jangan terlalu jauh.',
    Icons.rotate_left_rounded,
  ),
  _EnrollStage.right: _StageDef(
    'Tengok kanan sedikit',
    'Putar kepala sedikit ke kanan, jangan terlalu jauh.',
    Icons.rotate_right_rounded,
  ),
  _EnrollStage.blink: _StageDef(
    'Kedipkan mata 2x',
    'Validasi bahwa pendaftaran dilakukan oleh manusia secara langsung.',
    Icons.visibility_rounded,
  ),
};

const List<_EnrollStage> _scanStages = [
  _EnrollStage.center,
  _EnrollStage.left,
  _EnrollStage.right,
];

class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen>
    with WidgetsBindingObserver {
  static const int _samplesPerStage = 4;
  static const int _targetEmbeddingCount = _samplesPerStage * 3;
  static const Duration _frameThrottle = Duration(milliseconds: 260);
  static const Duration _stageSettleDelay = Duration(milliseconds: 650);
  static const int _stableFramesRequired = 3;
  static const double _maxYawDeltaPerFrame = 7.0;
  static const double _maxPitchDeltaPerFrame = 5.0;
  static const double _maxRollDeltaPerFrame = 5.0;

  CameraController? _camCtrl;
  _EnrollStep _step = _EnrollStep.capture;
  _ScanStatus _scanStatus = _ScanStatus.ready;
  _EnrollStage _stage = _EnrollStage.center;
  String? _errorMsg;

  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableClassification: true,
      enableLandmarks: true,
      enableContours: true,
      enableTracking: true,
    ),
  );

  final Map<_EnrollStage, List<_FrameCandidate>> _samples = {
    for (final stage in _scanStages) stage: <_FrameCandidate>[],
  };

  bool _disposed = false;
  bool _processingFrame = false;
  bool _stageChanging = false;
  bool _eyesPreviouslyClosed = false;
  int _blinkCount = 0;
  int _stableFrameCount = 0;
  double? _lastYaw;
  double? _lastPitch;
  double? _lastRoll;
  DateTime _lastFrameAt = DateTime(0);
  String _scanHint = 'Tekan Mulai saat wajah sudah siap';

  int get _collectedSamples {
    return _scanStages.fold<int>(
      0,
      (sum, stage) => sum + (_samples[stage]?.length ?? 0),
    );
  }

  int get _currentStageSamples => _samples[_stage]?.length ?? 0;

  bool get _needsPoseSamples => _scanStages.contains(_stage);

  bool get _isScanning => _scanStatus == _ScanStatus.scanning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ScreenBrightnessService.instance.acquireMax());
    unawaited(_initFaceRecognition());
    unawaited(_initCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      unawaited(_stopImageStream());
      _camCtrl?.dispose();
      _camCtrl = null;
      unawaited(ScreenBrightnessService.instance.releaseMax());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(ScreenBrightnessService.instance.acquireMax());
      unawaited(_initCamera());
    }
  }

  Future<void> _initFaceRecognition() async {
    try {
      await FaceRecognitionService.instance.init();
    } catch (e) {
      if (!mounted || _disposed) return;
      setState(() {
        _errorMsg = 'Gagal memuat model pengenalan wajah: ${e.toString()}';
        _step = _EnrollStep.error;
      });
    }
  }

  Future<void> _initCamera() async {
    try {
      final previous = _camCtrl;
      _camCtrl = null;
      await previous?.dispose();

      final cameras = await availableCameras();
      if (cameras.isEmpty || !mounted || _disposed) return;

      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final ctrl = CameraController(
        front,
        ResolutionPreset.medium,
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

      try {
        await ctrl.setExposureMode(ExposureMode.auto);
        await ctrl.setExposureOffset(0.0);
      } catch (_) {}
      try {
        await ctrl.setFocusMode(FocusMode.auto);
      } catch (_) {}

      setState(() => _camCtrl = ctrl);
    } catch (_) {
      if (!mounted || _disposed) return;
      setState(() {
        _errorMsg =
            'Gagal membuka kamera. Pastikan izin kamera aktif, lalu coba lagi.';
        _step = _EnrollStep.error;
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopImageStream());
    WidgetsBinding.instance.removeObserver(this);
    _detector.close();
    _camCtrl?.dispose();
    FaceRecognitionService.instance.dispose();
    unawaited(ScreenBrightnessService.instance.releaseMax());
    super.dispose();
  }

  Future<void> _startImageStream() async {
    final ctrl = _camCtrl;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        ctrl.value.isStreamingImages ||
        _disposed ||
        _step != _EnrollStep.capture ||
        !_isScanning) {
      return;
    }

    try {
      await ctrl.startImageStream(_onCameraFrame);
    } catch (_) {}
  }

  Future<void> _stopImageStream() async {
    final ctrl = _camCtrl;
    if (ctrl == null ||
        !ctrl.value.isInitialized ||
        !ctrl.value.isStreamingImages) {
      return;
    }

    try {
      await ctrl.stopImageStream();
    } catch (_) {}
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (_processingFrame ||
        _stageChanging ||
        _disposed ||
        _step != _EnrollStep.capture ||
        !_isScanning) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < _frameThrottle) return;
    _lastFrameAt = now;
    _processingFrame = true;

    try {
      if (!Platform.isAndroid) {
        _setHint('Live enrollment saat ini dioptimalkan untuk Android.');
        return;
      }

      final inputImage = _buildInputImage(image);
      final rotation = _currentRotation();
      if (inputImage == null || rotation == null) return;

      final faces = await _detector.processImage(inputImage);
      if (!mounted || _disposed || _step != _EnrollStep.capture) return;

      if (faces.isEmpty) {
        _setHint('Arahkan wajah ke kamera');
        return;
      }
      if (faces.length > 1) {
        _setHint('Pastikan hanya satu wajah di kamera');
        return;
      }

      final face = faces.first;
      final quality = _evaluateEnrollmentQuality(
        face,
        image.width,
        image.height,
      );
      if (!quality.accepted) {
        _setHint(quality.rejectReason ?? 'Posisikan wajah dengan jelas');
        return;
      }

      final features = _evaluateEnrollmentFeatures(face);
      if (!features.accepted) {
        _setHint(features.rejectReason ?? 'Pastikan wajah terlihat lengkap');
        return;
      }

      if (_needsPoseSamples) {
        await _handlePoseFrame(
          image,
          rotation,
          face,
          quality.score,
          features.score,
        );
      } else {
        await _handleBlinkFrame(face);
      }
    } catch (_) {
      // Ignore per-frame errors so the camera preview stays smooth.
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _handlePoseFrame(
    CameraImage image,
    InputImageRotation rotation,
    Face face,
    double qualityScore,
    double featureScore,
  ) async {
    if (!_poseMatchesStage(face, _stage)) {
      _resetPoseStability();
      _setHint(_poseHint(_stage, face));
      return;
    }

    if (!_isPoseStable(face)) {
      _setHint('Tahan posisi sebentar...');
      return;
    }

    final list = _samples[_stage]!;
    if (list.length >= _samplesPerStage) return;

    final fullImage = _cameraImageToImage(image, rotation);
    final faceCrop = fullImage == null
        ? null
        : FaceRecognitionService.instance.cropFace(fullImage, face);
    if (faceCrop == null) {
      _setHint('Crop wajah belum stabil. Tahan posisi sebentar...');
      return;
    }

    list.add(
      _FrameCandidate(
        nv21Bytes: Uint8List.fromList(image.planes.first.bytes),
        rawWidth: image.width,
        rawHeight: image.height,
        rotation: rotation,
        face: face,
        faceCrop: faceCrop,
        qualityScore: qualityScore,
        featureScore: featureScore,
      ),
    );

    _setHint('Sampel ${list.length} / $_samplesPerStage tersimpan');
    setState(() {});

    if (list.length >= _samplesPerStage) {
      await _advanceStage();
    }
  }

  Future<void> _handleBlinkFrame(Face face) async {
    if (face.leftEyeOpenProbability == null ||
        face.rightEyeOpenProbability == null) {
      _setHint('Hadapkan wajah ke depan lalu kedipkan mata');
      return;
    }

    final leftOpen = face.leftEyeOpenProbability! > 0.5;
    final rightOpen = face.rightEyeOpenProbability! > 0.5;
    final bothClosed = !leftOpen && !rightOpen;

    if (bothClosed) {
      _eyesPreviouslyClosed = true;
    } else if (_eyesPreviouslyClosed && leftOpen && rightOpen) {
      _blinkCount++;
      _eyesPreviouslyClosed = false;
    }

    if (_blinkCount >= 2) {
      _setHint('Liveness berhasil. Mengoptimalkan data wajah...');
      await _stopImageStream();
      await _finalize();
      return;
    }

    _setHint(
      _blinkCount == 0 ? 'Kedipkan mata 2x' : 'Kedipan: $_blinkCount / 2',
    );
  }

  Future<void> _advanceStage() async {
    if (_stageChanging) return;
    _stageChanging = true;
    _resetPoseStability();

    final index = _scanStages.indexOf(_stage);
    final next = index >= 0 && index < _scanStages.length - 1
        ? _scanStages[index + 1]
        : _EnrollStage.blink;

    if (!mounted || _disposed) return;
    setState(() {
      _stage = next;
      _scanHint = _stage == _EnrollStage.blink
          ? 'Kedipkan mata 2x'
          : _stageDefs[_stage]!.subtitle;
    });

    await Future.delayed(_stageSettleDelay);
    _stageChanging = false;
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

  FrameQualityResult _evaluateEnrollmentQuality(
    Face face,
    int frameWidth,
    int frameHeight,
  ) {
    final quality = FaceQualityFilter.evaluateFast(
      face,
      frameWidth,
      frameHeight,
    );
    if (quality.accepted || _stage == _EnrollStage.center) return quality;

    final yaw = face.headEulerAngleY?.abs();
    final yawRejected =
        quality.rejectReason == 'Hadapkan wajah ke depan' &&
        yaw != null &&
        yaw > 10;

    if (!yawRejected ||
        (_stage != _EnrollStage.left && _stage != _EnrollStage.right)) {
      return quality;
    }

    final pitch = face.headEulerAngleX?.abs();
    final roll = face.headEulerAngleZ?.abs();
    if (pitch != null && pitch > 18) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Jangan terlalu menunduk atau mendongak',
      );
    }
    if (roll != null && roll > 14) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Jaga kepala tetap tegak',
      );
    }

    final faceHeightRatio = face.boundingBox.height / frameHeight;
    final sizeScore = (faceHeightRatio / 0.45).clamp(0.0, 1.0);
    final rollScore = roll != null ? (1.0 - roll / 14.0).clamp(0.0, 1.0) : 1.0;
    final score = (sizeScore * 0.6 + rollScore * 0.4).clamp(0.0, 1.0);
    return FrameQualityResult(accepted: true, score: score);
  }

  _FeatureCheckResult _evaluateEnrollmentFeatures(Face face) {
    final requiredLandmarks = [
      FaceLandmarkType.leftEye,
      FaceLandmarkType.rightEye,
      FaceLandmarkType.noseBase,
      FaceLandmarkType.leftMouth,
      FaceLandmarkType.rightMouth,
      FaceLandmarkType.bottomMouth,
    ];
    final missing = requiredLandmarks
        .where((type) => face.landmarks[type] == null)
        .length;
    if (missing >= 3) {
      return const _FeatureCheckResult(
        accepted: false,
        score: 0,
        rejectReason: 'Pastikan wajah tidak tertutup',
      );
    }

    final eyeLandmarksOk =
        face.landmarks[FaceLandmarkType.leftEye] != null &&
        face.landmarks[FaceLandmarkType.rightEye] != null;
    if (!eyeLandmarksOk) {
      return const _FeatureCheckResult(
        accepted: false,
        score: 0,
        rejectReason: 'Pastikan kedua mata terlihat jelas',
      );
    }

    final eyeOpenAvailable =
        face.leftEyeOpenProbability != null &&
        face.rightEyeOpenProbability != null;
    if (!eyeOpenAvailable) {
      return const _FeatureCheckResult(
        accepted: false,
        score: 0,
        rejectReason: 'Hadapkan wajah agar mata terdeteksi',
      );
    }

    final contourPoints = _contourPointCount(face);
    if (contourPoints < 40) {
      return const _FeatureCheckResult(
        accepted: false,
        score: 0,
        rejectReason: 'Pastikan seluruh wajah masuk frame',
      );
    }

    final mouthRatio = _mouthOpeningRatio(face);
    if (mouthRatio == null) {
      return const _FeatureCheckResult(
        accepted: false,
        score: 0,
        rejectReason: 'Pastikan mulut dan hidung terlihat',
      );
    }

    final landmarkScore = (1.0 - missing / requiredLandmarks.length).clamp(
      0.0,
      1.0,
    );
    final contourScore = (contourPoints / 68.0).clamp(0.0, 1.0);
    final leftEye = face.leftEyeOpenProbability!.clamp(0.0, 1.0);
    final rightEye = face.rightEyeOpenProbability!.clamp(0.0, 1.0);
    final eyeScore = ((leftEye + rightEye) / 2.0).clamp(0.0, 1.0);
    final mouthScore = (1.0 - (mouthRatio - 0.025).abs() / 0.08).clamp(
      0.0,
      1.0,
    );

    final score =
        (landmarkScore * 0.30 +
                contourScore * 0.25 +
                eyeScore * 0.25 +
                mouthScore * 0.20)
            .clamp(0.0, 1.0);

    return _FeatureCheckResult(accepted: true, score: score);
  }

  static int _contourPointCount(Face face) {
    return face.contours.values.fold<int>(
      0,
      (sum, contour) => sum + (contour?.points.length ?? 0),
    );
  }

  static double? _mouthOpeningRatio(Face face) {
    if (face.boundingBox.height <= 0) return null;
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) {
      final top = face.landmarks[FaceLandmarkType.noseBase]?.position;
      final bottom = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
      if (top == null || bottom == null) return null;
      return (bottom.y - top.y).abs() / face.boundingBox.height;
    }

    final upperY = upper.map((p) => p.y).reduce((a, b) => a + b) / upper.length;
    final lowerY = lower.map((p) => p.y).reduce((a, b) => a + b) / lower.length;
    return (lowerY - upperY).abs() / face.boundingBox.height;
  }

  bool _poseMatchesStage(Face face, _EnrollStage stage) {
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX?.abs();
    final roll = face.headEulerAngleZ?.abs();

    if (yaw == null) return false;
    if (pitch != null && pitch > 18) return false;
    if (roll != null && roll > 14) return false;

    switch (stage) {
      case _EnrollStage.center:
        return yaw.abs() <= 10;
      case _EnrollStage.left:
        return yaw >= 10 && yaw <= 45;
      case _EnrollStage.right:
        return yaw <= -10 && yaw >= -45;
      case _EnrollStage.blink:
        return true;
    }
  }

  String _poseHint(_EnrollStage stage, Face face) {
    final yaw = face.headEulerAngleY ?? 0;
    switch (stage) {
      case _EnrollStage.center:
        return yaw.abs() <= 10 ? 'Tahan posisi...' : 'Hadapkan wajah lurus';
      case _EnrollStage.left:
        return 'Tengok kiri 10-45 derajat';
      case _EnrollStage.right:
        return 'Tengok kanan 10-45 derajat';
      case _EnrollStage.blink:
        return 'Kedipkan mata 2x';
    }
  }

  Future<void> _finalize() async {
    if (!mounted || _disposed) return;
    setState(() => _step = _EnrollStep.processing);

    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) throw Exception('Sesi tidak ditemukan');

      final candidates = _orderedCandidates();
      if (candidates.length < _targetEmbeddingCount) {
        throw Exception('Sampel wajah belum lengkap');
      }

      final embeddings = <List<double>>[];
      for (final candidate in candidates.take(_targetEmbeddingCount)) {
        final embedding = await FaceRecognitionService.instance
            .extractEmbeddingFromNv21(
              nv21Bytes: candidate.nv21Bytes,
              width: candidate.rawWidth,
              height: candidate.rawHeight,
              rotation: candidate.rotation,
              face: candidate.face,
              enforceQuality: false,
            );
        if (embedding != null) embeddings.add(embedding);
      }

      if (embeddings.length < _targetEmbeddingCount) {
        throw Exception(
          'Data wajah belum cukup jelas. Coba ulangi pendaftaran.',
        );
      }

      final compactedEmbeddings = _compactEnrollmentEmbeddings(embeddings);
      if (compactedEmbeddings.length < _scanStages.length) {
        throw Exception(
          'Data wajah belum cukup konsisten. Coba ulangi pendaftaran.',
        );
      }

      await EmbeddingSyncService.instance.saveEmbeddings(
        uid,
        compactedEmbeddings,
      );

      if (!mounted || _disposed) return;
      setState(() => _step = _EnrollStep.done);
    } on DuplicateFaceException {
      if (!mounted || _disposed) return;
      setState(() {
        _errorMsg =
            'Wajah ini sudah terdaftar di akun lain. Gunakan wajah pemilik akun ini.';
        _step = _EnrollStep.error;
      });
    } catch (e) {
      if (!mounted || _disposed) return;
      final rawError = e.toString();
      final friendlyError = rawError.contains('failed precondition')
          ? 'Gagal menyimpan data wajah ke server. Kemungkinan schema Supabase belum sesuai atau fungsi duplicate-check belum terpasang.'
          : 'Gagal menyimpan data wajah: $rawError';
      setState(() {
        _errorMsg = friendlyError;
        _step = _EnrollStep.error;
      });
    }
  }

  List<_FrameCandidate> _orderedCandidates() {
    final selected = <_FrameCandidate>[];
    for (final stage in _scanStages) {
      final stageSamples = List<_FrameCandidate>.from(_samples[stage] ?? []);
      stageSamples.sort((a, b) => b.trainingScore.compareTo(a.trainingScore));
      selected.addAll(stageSamples.take(_samplesPerStage));
    }
    return selected;
  }

  List<List<double>> _compactEnrollmentEmbeddings(
    List<List<double>> embeddings,
  ) {
    final compacted = <List<double>>[];
    for (
      int offset = 0;
      offset < embeddings.length;
      offset += _samplesPerStage
    ) {
      final group = embeddings.skip(offset).take(_samplesPerStage).toList();
      if (group.isEmpty) continue;
      compacted.add(
        group.length == 1
            ? group.first
            : FaceRecognitionService.bestEmbedding(group),
      );
    }
    return compacted;
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

  InputImage? _buildInputImage(CameraImage image) {
    final rotation = _currentRotation();
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
    final ctrl = _camCtrl;
    if (ctrl == null) return null;

    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(
        ctrl.description.sensorOrientation,
      );
    }

    int rotationCompensation = ctrl.description.sensorOrientation;
    final deviceOrientation = ctrl.value.deviceOrientation;
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

    if (ctrl.description.lensDirection == CameraLensDirection.front) {
      rotationCompensation =
          (ctrl.description.sensorOrientation + deviceRot) % 360;
    } else {
      rotationCompensation =
          (ctrl.description.sensorOrientation - deviceRot + 360) % 360;
    }

    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  void _setHint(String hint) {
    if (!mounted || _disposed || _scanHint == hint) return;
    setState(() => _scanHint = hint);
  }

  void _startScan() {
    if (_isScanning || _step != _EnrollStep.capture) return;
    setState(() {
      _scanStatus = _ScanStatus.scanning;
      _stage = _EnrollStage.center;
      _scanHint = _stageDefs[_EnrollStage.center]!.subtitle;
      _resetPoseStability();
    });
    unawaited(_startImageStream());
  }

  void _restart() {
    for (final stage in _scanStages) {
      _samples[stage]!.clear();
    }
    setState(() {
      _step = _EnrollStep.capture;
      _scanStatus = _ScanStatus.ready;
      _stage = _EnrollStage.center;
      _errorMsg = null;
      _processingFrame = false;
      _stageChanging = false;
      _eyesPreviouslyClosed = false;
      _blinkCount = 0;
      _resetPoseStability();
      _scanHint = 'Tekan Mulai saat wajah sudah siap';
    });
    if (_camCtrl == null || !_camCtrl!.value.isInitialized) {
      unawaited(_initCamera());
    }
    unawaited(_initFaceRecognition());
  }

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
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary,
          ),
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
      case _EnrollStep.capture:
        return _buildCaptureStep();
    }
  }

  Widget _buildCaptureStep() {
    if (!_isScanning) {
      return _buildReadyStep();
    }

    return Column(
      children: [
        const SizedBox(height: 16),
        _buildStageProgress(),
        const SizedBox(height: 10),
        _buildInstruction(),
        const SizedBox(height: 12),
        Expanded(child: _buildCameraPreview()),
        const SizedBox(height: 12),
        _buildScanStatus(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildReadyStep() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
        children: [
          Expanded(child: _buildCameraPreview()),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.face_retouching_natural_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Siapkan wajah di dalam kamera. Setelah mulai, ikuti arahan lurus, kiri, kanan, lalu kedipkan mata 2x.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _camCtrl?.value.isInitialized == true
                  ? _startScan
                  : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 22),
              label: const Text(
                'Mulai Daftarkan Wajah',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStageProgress() {
    final total = _scanStages.length + 1;
    final activeIndex = _stage == _EnrollStage.blink
        ? _scanStages.length
        : _scanStages.indexOf(_stage);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _isScanning ? 20 : 0),
      child: Row(
        children: List.generate(total, (i) {
          final done = i < activeIndex;
          final active = i == activeIndex;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < total - 1 ? 6 : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 6,
                decoration: BoxDecoration(
                  color: done
                      ? AppColors.success
                      : active
                      ? AppColors.primary
                      : AppColors.border,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildInstruction() {
    final stage = _stageDefs[_stage]!;
    final stageNumber = _stage == _EnrollStage.blink
        ? _scanStages.length + 1
        : _scanStages.indexOf(_stage) + 1;

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
            Icon(stage.icon, color: AppColors.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Langkah $stageNumber / 4 - ${stage.label}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stage.subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            Positioned(
              left: 14,
              right: 14,
              bottom: 14,
              child: _buildLiveBadge(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveBadge() {
    final done = _stage == _EnrollStage.blink && _blinkCount >= 2;
    return Align(
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: done
              ? AppColors.success.withValues(alpha: 0.90)
              : Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              done ? Icons.verified_user_rounded : _stageDefs[_stage]!.icon,
              size: 17,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _isScanning ? _scanHint : 'Siapkan posisi wajah',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanStatus() {
    final label = _stage == _EnrollStage.blink
        ? 'Kedipan $_blinkCount / 2'
        : 'Sampel $_currentStageSamples / $_samplesPerStage';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$label - Total $_collectedSamples / $_targetEmbeddingCount',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessing() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.primary),
          SizedBox(height: 20),
          Text(
            'Mengoptimalkan data wajah...',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Aplikasi sedang memilih sampel terbaik, membuat embedding, lalu menyimpannya ke perangkat serta Supabase.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
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
              '9 sampel wajah terbaik berdasarkan kualitas dan fitur wajah telah disimpan dengan aman.\n'
              'Anda sekarang dapat menggunakan absensi wajah.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
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
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Selesai',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
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
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Coba Lagi',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
