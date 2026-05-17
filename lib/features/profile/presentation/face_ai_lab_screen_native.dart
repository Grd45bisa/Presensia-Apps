import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../../shared/services/face/face_quality_filter.dart';
import '../../../shared/services/face/face_recognition_service.dart';
import '../../../shared/theme/app_colors.dart';

class FaceAiLabScreen extends StatefulWidget {
  const FaceAiLabScreen({super.key});

  @override
  State<FaceAiLabScreen> createState() => _FaceAiLabScreenState();
}

class _FaceAiLabScreenState extends State<FaceAiLabScreen> {
  final _picker = ImagePicker();
  final _sFace = _SFaceLabModel();
  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableClassification: true,
      enableLandmarks: true,
      enableContours: true,
      enableTracking: false,
    ),
  );

  final List<_FaceSample> _training = [];
  _FaceSample? _proof;
  bool _busy = false;

  static const double _labThreshold = 0.83;

  @override
  void initState() {
    super.initState();
    FaceRecognitionService.instance.init();
    _sFace.init();
  }

  @override
  void dispose() {
    _sFace.dispose();
    _detector.close();
    super.dispose();
  }

  Future<void> _pickTraining() async {
    final source = await _chooseImageSource(
      title: 'Tambah foto contoh',
      allowMultiGallery: true,
    );
    if (source == null) return;

    setState(() => _busy = true);
    try {
      final List<XFile> images;
      if (source == _PickSource.galleryMulti) {
        images = await _picker.pickMultiImage(imageQuality: 95);
      } else {
        final image = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 95,
        );
        images = image == null ? <XFile>[] : <XFile>[image];
      }
      if (images.isEmpty) {
        _showSnack('Tidak ada foto yang dipilih.');
        return;
      }

      final samples = <_FaceSample>[];
      for (final file in images) {
        samples.add(await _analyzeImage(file));
      }
      if (!mounted) return;
      setState(() => _training.addAll(samples));
    } catch (e) {
      _showSnack(_pickerErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickProof() async {
    final source = await _chooseImageSource(
      title: 'Pilih foto pembuktian',
      allowMultiGallery: false,
    );
    if (source == null) return;

    setState(() => _busy = true);
    try {
      final image = await _picker.pickImage(
        source: source == _PickSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        imageQuality: 95,
      );
      if (image == null) {
        _showSnack('Tidak ada foto yang dipilih.');
        return;
      }

      final sample = await _analyzeImage(image);
      if (!mounted) return;
      setState(() => _proof = sample);
    } catch (e) {
      _showSnack(_pickerErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_PickSource?> _chooseImageSource({
    required String title,
    required bool allowMultiGallery,
  }) {
    return showModalBottomSheet<_PickSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: Text(
                  allowMultiGallery
                      ? 'Pilih dari galeri (bisa banyak)'
                      : 'Pilih dari galeri',
                ),
                onTap: () => Navigator.pop(
                  ctx,
                  allowMultiGallery
                      ? _PickSource.galleryMulti
                      : _PickSource.gallerySingle,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: const Text('Ambil dari kamera'),
                onTap: () => Navigator.pop(ctx, _PickSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String _pickerErrorMessage(Object error) {
    if (error is PlatformException && error.code == 'channel-error') {
      return 'Picker foto belum aktif. Tutup app total lalu jalankan ulang dari Flutter setelah pub get.';
    }
    return 'Gagal membuka foto: $error';
  }

  Future<_FaceSample> _analyzeImage(XFile file) async {
    try {
      final bytes = await file.readAsBytes();
      final decodedRaw = img.decodeImage(bytes);
      final decoded = decodedRaw == null
          ? null
          : img.bakeOrientation(decodedRaw);
      if (decoded == null) {
        return _FaceSample(file: file, error: 'File gambar tidak terbaca.');
      }

      final faces = await _detector.processImage(
        InputImage.fromFilePath(file.path),
      );
      if (faces.isEmpty) {
        return _FaceSample(
          file: file,
          image: decoded,
          error: 'Wajah tidak terdeteksi.',
        );
      }
      if (faces.length > 1) {
        return _FaceSample(
          file: file,
          image: decoded,
          error: 'Terdeteksi lebih dari satu wajah.',
        );
      }

      final face = faces.first;
      final quality = FaceQualityFilter.evaluate(decoded, face);
      final faceCrop = FaceRecognitionService.instance.cropFace(decoded, face);
      List<double>? embedding;
      List<double>? sFaceEmbedding;
      String? error;
      if (quality.accepted && faceCrop != null) {
        try {
          embedding = await FaceRecognitionService.instance
              .extractEmbeddingFromCrop(faceCrop);
        } catch (e) {
          error = 'MobileFaceNet gagal: $e';
        }
        try {
          sFaceEmbedding = await _sFace.extract(faceCrop);
        } catch (e) {
          error ??= 'SFace gagal: $e';
        }
      } else {
        error = faceCrop == null
            ? 'Crop wajah tidak berhasil.'
            : quality.rejectReason ?? 'Kualitas wajah belum cukup baik.';
      }

      return _FaceSample(
        file: file,
        image: decoded,
        faceCrop: faceCrop,
        face: face,
        quality: quality,
        embedding: embedding,
        sFaceEmbedding: sFaceEmbedding,
        error: error,
      );
    } catch (e) {
      return _FaceSample(file: file, error: 'Gagal menganalisis: $e');
    }
  }

  _MatchSummary? get _match {
    final proofEmbedding = _proof?.embedding;
    final candidates = _training.where((s) => s.embedding != null).toList();
    if (proofEmbedding == null || candidates.isEmpty) return null;

    double best = -1;
    double euc = double.infinity;
    int bestIndex = -1;
    for (int i = 0; i < candidates.length; i++) {
      final stored = candidates[i].embedding!;
      final sim = FaceRecognitionService.cosineSimilarity(
        proofEmbedding,
        stored,
      );
      if (sim > best) {
        best = sim;
        euc = FaceRecognitionService.euclideanDistance(proofEmbedding, stored);
        bestIndex = i;
      }
    }
    return _MatchSummary(
      similarity: best.clamp(0.0, 1.0),
      euclidean: euc,
      bestIndex: bestIndex,
      passed: best >= _labThreshold,
    );
  }

  _MatchSummary? get _sFaceMatch {
    final proofEmbedding = _proof?.sFaceEmbedding;
    final candidates = _training
        .where((s) => s.sFaceEmbedding != null)
        .toList();
    if (proofEmbedding == null || candidates.isEmpty) return null;

    double best = -1;
    double euc = double.infinity;
    int bestIndex = -1;
    for (int i = 0; i < candidates.length; i++) {
      final stored = candidates[i].sFaceEmbedding!;
      final sim = FaceRecognitionService.cosineSimilarity(
        proofEmbedding,
        stored,
      );
      if (sim > best) {
        best = sim;
        euc = FaceRecognitionService.euclideanDistance(proofEmbedding, stored);
        bestIndex = i;
      }
    }
    return _MatchSummary(
      similarity: best.clamp(0.0, 1.0),
      euclidean: euc,
      bestIndex: bestIndex,
      passed: best >= _labThreshold,
    );
  }

  List<_ModelDecision> get _modelDecisions {
    final match = _match;
    if (match == null) {
      return const [
        _ModelDecision.pending('MobileFaceNet'),
        _ModelDecision.pending('MobileFaceNet + Quality Gate'),
        _ModelDecision.pending('MobileFaceNet + Feature Fusion'),
        _ModelDecision.pending('SFace'),
        _ModelDecision.inactive(
          'ArcFace / InsightFace',
          'Model belum dibundel',
        ),
      ];
    }

    final qualityOk = _qualityGateOk(_proof);
    final sFaceMatch = _sFaceMatch;
    final qualityScore = _proof?.quality?.score ?? 0;
    final featureOk = _featureGateOk(_proof);
    final featureScore = _featureScore(_proof);
    return [
      _decision(
        model: 'MobileFaceNet',
        predictedSame: match.passed,
        accuracy: match.similarity,
        detail: 'Embedding similarity murni',
      ),
      _decision(
        model: 'MobileFaceNet + Quality Gate',
        predictedSame: match.passed && qualityOk,
        accuracy: (match.similarity * 0.75 + qualityScore * 0.25),
        detail: qualityOk
            ? 'Similarity + kualitas wajah lolos'
            : 'Ditolak oleh face quality',
      ),
      _decision(
        model: 'MobileFaceNet + Feature Fusion',
        predictedSame: match.passed && featureOk,
        accuracy: match.similarity * 0.80 + featureScore * 0.20,
        detail: featureOk
            ? 'Similarity + pose + landmark + mata + mulut + occlusion'
            : 'Ditolak oleh fitur wajah pendukung',
      ),
      _decision(
        model: 'MobileFaceNet + Quality Gate + Feature Fusion',
        predictedSame: match.passed && qualityOk && featureOk,
        accuracy:
            match.similarity * 0.70 + qualityScore * 0.15 + featureScore * 0.15,
        detail: qualityOk && featureOk
            ? 'Similarity + quality + fitur wajah lengkap'
            : 'Ditolak oleh quality atau fitur wajah',
      ),
      if (sFaceMatch == null)
        _ModelDecision.inactive(
          'SFace',
          _sFace.lastError == null
              ? 'Menunggu embedding training dan foto uji'
              : 'SFace gagal: ${_sFace.lastError}',
        )
      else
        _decision(
          model: 'SFace',
          predictedSame: sFaceMatch.passed,
          accuracy: sFaceMatch.similarity,
          detail: 'SFace embedding similarity',
        ),
      const _ModelDecision.inactive(
        'ArcFace / InsightFace',
        'Model belum dibundel',
      ),
    ];
  }

  _ModelDecision _decision({
    required String model,
    required bool predictedSame,
    required double accuracy,
    required String detail,
  }) {
    return _ModelDecision(
      model: model,
      predictedSame: predictedSame,
      accuracy: accuracy.clamp(0.0, 1.0),
      detail: detail,
      active: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Face AI Testing Lab'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
        children: [
          _buildIntro(),
          const SizedBox(height: 16),
          _sectionTitle('Daftar / Training Foto'),
          const SizedBox(height: 8),
          _buildTrainingPanel(),
          const SizedBox(height: 16),
          _sectionTitle('Pembuktian / Foto Uji'),
          const SizedBox(height: 8),
          _buildProofPanel(match),
          const SizedBox(height: 16),
          _sectionTitle('Hasil Pembuktian Model'),
          const SizedBox(height: 8),
          _buildModelPanel(),
          const SizedBox(height: 16),
          _sectionTitle('Fitur yang Dipakai Model Fusion'),
          const SizedBox(height: 8),
          _buildFeaturePanel(),
        ],
      ),
    );
  }

  Widget _buildIntro() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Foto daftar/training adalah contoh wajah orang terdaftar. Foto '
            'pembuktian adalah wajah yang diuji apakah mirip atau tidak. Lab ini '
            'mengambil crop wajah, membuat template, lalu membandingkan skor tiap model.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 8),
            const Text(
              'Memproses semua model. Hasil akan tampil setelah selesai.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrainingPanel() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _pickTraining,
                  icon: const Icon(Icons.add_photo_alternate_rounded),
                  label: const Text('Tambah Foto'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: _busy || _training.isEmpty
                    ? null
                    : () => setState(_training.clear),
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: 'Kosongkan foto training',
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Masukkan foto contoh dari orang yang sama. Semakin bersih fotonya, semakin adil hasil uji model.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (_training.isEmpty)
            const _EmptyState(text: 'Belum ada foto training.')
          else
            ..._training.asMap().entries.map(
              (entry) => _SampleTile(
                title: 'Template ${entry.key + 1}',
                sample: entry.value,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProofPanel(_MatchSummary? match) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _pickProof,
              icon: const Icon(Icons.fact_check_rounded),
              label: const Text('Pilih Foto Uji'),
            ),
          ),
          const SizedBox(height: 12),
          if (_proof == null)
            const _EmptyState(text: 'Belum ada foto uji.')
          else
            _SampleTile(title: 'Foto Uji', sample: _proof!),
          if (match != null) ...[
            const SizedBox(height: 12),
            _ResultBanner(match: match),
          ],
        ],
      ),
    );
  }

  Widget _buildModelPanel() {
    final decisions = _modelDecisions;
    return Container(
      decoration: _panelDecoration(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 42,
          dataRowMinHeight: 54,
          dataRowMaxHeight: 70,
          columns: const [
            DataColumn(label: Text('Model')),
            DataColumn(label: Text('Akurasi')),
            DataColumn(label: Text('Hasil')),
          ],
          rows: decisions.map(_modelDataRow).toList(),
        ),
      ),
    );
  }

  Widget _buildFeaturePanel() {
    final sample = _proof ?? (_training.isNotEmpty ? _training.last : null);
    final features = _featuresFor(sample);
    return Container(
      decoration: _panelDecoration(),
      child: Column(
        children: [
          for (int i = 0; i < features.length; i++) ...[
            _featureRow(features[i]),
            if (i != features.length - 1) _divider(),
          ],
        ],
      ),
    );
  }

  List<_FeatureStatus> _featuresFor(_FaceSample? sample) {
    final face = sample?.face;
    final contourPoints = _contourPointCount(face);
    final quality = sample?.quality;
    return [
      _FeatureStatus(
        'Face Detection',
        face != null,
        face == null ? '-' : '1 wajah',
      ),
      _FeatureStatus(
        'Face Templates Extraction',
        sample?.embedding != null,
        sample?.embedding == null
            ? 'Belum ada embedding'
            : '${sample!.embedding!.length} dimensi',
      ),
      _FeatureStatus(
        'Face Matching',
        _match != null,
        _match == null
            ? 'Butuh template dan foto uji'
            : '${(_match!.similarity * 100).toStringAsFixed(1)}%',
      ),
      _FeatureStatus(
        'Pose Estimation',
        face?.headEulerAngleY != null,
        face == null
            ? '-'
            : 'yaw ${_deg(face.headEulerAngleY)}, pitch ${_deg(face.headEulerAngleX)}, roll ${_deg(face.headEulerAngleZ)}',
      ),
      _FeatureStatus(
        '68-point Landmark',
        contourPoints >= 68,
        '$contourPoints contour point',
      ),
      _FeatureStatus(
        'Face Quality Calculation',
        quality != null,
        quality == null ? '-' : '${(quality.score * 100).toStringAsFixed(0)}%',
      ),
      _FeatureStatus(
        'Eye Closure Detection',
        _hasEyeProb(face),
        _eyeText(face),
      ),
      _FeatureStatus(
        'Mouth Opening Check',
        _mouthOpeningRatio(face) != null,
        _mouthText(face),
      ),
      _FeatureStatus(
        'Face Occlusion Detection',
        face != null,
        _occlusionText(face, quality),
      ),
    ];
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      ),
    );
  }

  DataRow _modelDataRow(_ModelDecision decision) {
    final accuracyText = decision.active
        ? '${((decision.accuracy ?? 0) * 100).toStringAsFixed(0)}%'
        : '-';

    return DataRow(
      cells: [
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  decision.model,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  decision.detail,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(Text(accuracyText)),
        DataCell(
          Text(
            decision.predictedSame == null
                ? 'Pending'
                : (decision.predictedSame! ? 'Mirip' : 'Tidak'),
            style: TextStyle(
              color: decision.predictedSame == true
                  ? AppColors.success
                  : decision.predictedSame == false
                  ? AppColors.error
                  : AppColors.textSecondary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _featureRow(_FeatureStatus feature) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            feature.ok
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked,
            color: feature.ok ? AppColors.success : AppColors.textSecondary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  feature.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  feature.detail,
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
    );
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    );
  }

  Widget _divider() => const Divider(
    height: 1,
    indent: 14,
    endIndent: 14,
    color: AppColors.border,
  );

  static int _contourPointCount(Face? face) {
    if (face == null) return 0;
    return face.contours.values.fold<int>(
      0,
      (sum, contour) => sum + (contour?.points.length ?? 0),
    );
  }

  static bool _qualityGateOk(_FaceSample? sample) {
    final quality = sample?.quality;
    return quality != null && quality.accepted && quality.score >= 0.55;
  }

  static bool _featureGateOk(_FaceSample? sample) {
    final face = sample?.face;
    if (face == null) return false;

    final yaw = face.headEulerAngleY?.abs();
    final pitch = face.headEulerAngleX?.abs();
    final roll = face.headEulerAngleZ?.abs();
    final poseOk =
        (yaw == null || yaw <= 18) &&
        (pitch == null || pitch <= 18) &&
        (roll == null || roll <= 14);

    final landmarksOk =
        face.landmarks[FaceLandmarkType.leftEye] != null &&
        face.landmarks[FaceLandmarkType.rightEye] != null &&
        face.landmarks[FaceLandmarkType.noseBase] != null;

    final contourOk = _contourPointCount(face) >= 68;
    final eyeOk = _hasEyeProb(face);
    final mouthOk = _mouthOpeningRatio(face) != null;
    final occlusionOk = !_occlusionText(
      face,
      sample?.quality,
    ).startsWith('Kemungkinan');

    return poseOk &&
        landmarksOk &&
        contourOk &&
        eyeOk &&
        mouthOk &&
        occlusionOk;
  }

  static double _featureScore(_FaceSample? sample) {
    final face = sample?.face;
    if (face == null) return 0;

    final checks = <bool>[
      _contourPointCount(face) >= 68,
      _hasEyeProb(face),
      _mouthOpeningRatio(face) != null,
      !_occlusionText(face, sample?.quality).startsWith('Kemungkinan'),
      (face.headEulerAngleY?.abs() ?? 0) <= 18,
      (face.headEulerAngleX?.abs() ?? 0) <= 18,
      (face.headEulerAngleZ?.abs() ?? 0) <= 14,
    ];
    final passed = checks.where((ok) => ok).length;
    return passed / checks.length;
  }

  static String _deg(double? value) =>
      value == null ? '-' : '${value.toStringAsFixed(1)}°';

  static bool _hasEyeProb(Face? face) =>
      face?.leftEyeOpenProbability != null &&
      face?.rightEyeOpenProbability != null;

  static String _eyeText(Face? face) {
    if (!_hasEyeProb(face)) return 'Probabilitas mata tidak tersedia';
    final left = face!.leftEyeOpenProbability!;
    final right = face.rightEyeOpenProbability!;
    final closed = left < 0.35 && right < 0.35;
    return closed
        ? 'Mata tertutup'
        : 'L ${(left * 100).toStringAsFixed(0)}%, R ${(right * 100).toStringAsFixed(0)}%';
  }

  static double? _mouthOpeningRatio(Face? face) {
    if (face == null || face.boundingBox.height <= 0) return null;
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

  static String _mouthText(Face? face) {
    final ratio = _mouthOpeningRatio(face);
    if (ratio == null) return 'Kontur mulut tidak tersedia';
    return ratio > 0.045
        ? 'Mulut terbuka (${(ratio * 100).toStringAsFixed(1)}%)'
        : 'Mulut tertutup (${(ratio * 100).toStringAsFixed(1)}%)';
  }

  static String _occlusionText(Face? face, FrameQualityResult? quality) {
    if (face == null) return '-';
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
    if (missing >= 3) return 'Kemungkinan tertutup: $missing landmark hilang';
    if (quality != null && !quality.accepted) {
      return 'Perlu cek ulang: ${quality.rejectReason}';
    }
    return 'Tidak terindikasi tertutup';
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({required this.title, required this.sample});

  final String title;
  final _FaceSample sample;

  @override
  Widget build(BuildContext context) {
    final ok = sample.embedding != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ok ? AppColors.successLight : AppColors.errorLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _SampleThumb(sample: sample),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  ok
                      ? 'Template siap - kualitas ${(sample.quality!.score * 100).toStringAsFixed(0)}%'
                      : sample.error ?? 'Belum siap',
                  style: TextStyle(
                    fontSize: 12,
                    color: ok ? AppColors.success : AppColors.error,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            ok ? Icons.check_rounded : Icons.warning_amber_rounded,
            color: ok ? AppColors.success : AppColors.error,
          ),
        ],
      ),
    );
  }
}

class _SampleThumb extends StatelessWidget {
  const _SampleThumb({required this.sample});

  final _FaceSample sample;

  @override
  Widget build(BuildContext context) {
    final crop = sample.faceCrop;
    final bytes = crop == null
        ? null
        : Uint8List.fromList(img.encodeJpg(crop, quality: 88));

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: bytes == null
          ? Image.file(
              File(sample.file.path),
              width: 58,
              height: 58,
              fit: BoxFit.cover,
            )
          : Image.memory(bytes, width: 58, height: 58, fit: BoxFit.cover),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.match});

  final _MatchSummary match;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: match.passed ? AppColors.successLight : AppColors.errorLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            match.passed ? Icons.verified_user_rounded : Icons.block_rounded,
            color: match.passed ? AppColors.success : AppColors.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${match.passed ? 'Lolos' : 'Tidak lolos'} - '
              '${match.passed ? 'wajah mirip' : 'wajah tidak mirip'}, '
              'similarity ${(match.similarity * 100).toStringAsFixed(1)}%, '
              'distance ${match.euclidean.toStringAsFixed(3)}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: match.passed ? AppColors.success : AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
    );
  }
}

class _FaceSample {
  const _FaceSample({
    required this.file,
    this.image,
    this.faceCrop,
    this.face,
    this.quality,
    this.embedding,
    this.sFaceEmbedding,
    this.error,
  });

  final XFile file;
  final img.Image? image;
  final img.Image? faceCrop;
  final Face? face;
  final FrameQualityResult? quality;
  final List<double>? embedding;
  final List<double>? sFaceEmbedding;
  final String? error;
}

class _MatchSummary {
  const _MatchSummary({
    required this.similarity,
    required this.euclidean,
    required this.bestIndex,
    required this.passed,
  });

  final double similarity;
  final double euclidean;
  final int bestIndex;
  final bool passed;
}

class _FeatureStatus {
  const _FeatureStatus(this.name, this.ok, this.detail);

  final String name;
  final bool ok;
  final String detail;
}

enum _PickSource { gallerySingle, galleryMulti, camera }

class _ModelDecision {
  const _ModelDecision({
    required this.model,
    required this.predictedSame,
    required this.accuracy,
    required this.detail,
    required this.active,
  });

  const _ModelDecision.pending(String model)
    : this(
        model: model,
        predictedSame: null,
        accuracy: null,
        detail: 'Butuh foto contoh dan foto uji',
        active: true,
      );

  const _ModelDecision.inactive(String model, String detail)
    : this(
        model: model,
        predictedSame: null,
        accuracy: null,
        detail: detail,
        active: false,
      );

  final String model;
  final bool? predictedSame;
  final double? accuracy;
  final String detail;
  final bool active;
}

class _SFaceLabModel {
  Interpreter? _interpreter;
  int _inputSize = 112;
  bool _nchw = false;
  bool _uint8Input = false;
  bool _ready = false;
  Future<void>? _initFuture;
  List<int> _outputShape = const [1, 128];
  String? lastError;

  Future<void> init() async {
    if (_ready) return;
    final running = _initFuture;
    if (running != null) return running;
    _initFuture = _init();
    return _initFuture;
  }

  Future<void> _init() async {
    try {
      final interpreter = await Interpreter.fromAsset(
        'assets/models/sface.tflite',
      );
      final inputTensor = interpreter.getInputTensor(0);
      final inputShape = inputTensor.shape;
      final outputShape = interpreter.getOutputTensor(0).shape;
      _outputShape = List<int>.from(outputShape);
      _uint8Input = inputTensor.type == TensorType.uint8;

      if (inputShape.length == 4) {
        _nchw = inputShape[1] == 3;
        _inputSize = _nchw ? inputShape[2] : inputShape[1];
      }
      _interpreter = interpreter;
      _ready = true;
      lastError = null;
      // ignore: avoid_print
      print(
        '[SFaceLab] loaded input=$inputShape type=${inputTensor.type} '
        'output=$outputShape nchw=$_nchw',
      );
    } catch (e) {
      lastError = e.toString();
      // ignore: avoid_print
      print('[SFaceLab] failed to load: $e');
    } finally {
      _initFuture = null;
    }
  }

  Future<List<double>?> extract(img.Image faceCrop) async {
    if (!_ready) await init();
    final interpreter = _interpreter;
    if (interpreter == null) return null;

    final resized = img.copyResize(
      faceCrop,
      width: _inputSize,
      height: _inputSize,
    );
    final input = _uint8Input
        ? (_nchw ? _nchwInputUint8(resized) : _nhwcInputUint8(resized))
        : (_nchw ? _nchwInputFloat(resized) : _nhwcInputFloat(resized));
    final output = _makeOutputBuffer(_outputShape);

    try {
      interpreter.run(input, output);
      final embedding = _flattenOutput(output);
      if (embedding.isEmpty) {
        lastError = 'Output SFace kosong.';
        return null;
      }
      lastError = null;
      return _normalize(embedding);
    } catch (e) {
      lastError = e.toString();
      // ignore: avoid_print
      print('[SFaceLab] inference failed: $e');
      return null;
    }
  }

  List<List<List<List<double>>>> _nhwcInputFloat(img.Image image) {
    return [
      List.generate(_inputSize, (y) {
        return List.generate(_inputSize, (x) {
          final p = image.getPixel(x, y);
          return [
            (p.r.toDouble() - 127.5) / 127.5,
            (p.g.toDouble() - 127.5) / 127.5,
            (p.b.toDouble() - 127.5) / 127.5,
          ];
        });
      }),
    ];
  }

  List<List<List<List<double>>>> _nchwInputFloat(img.Image image) {
    return [
      List.generate(3, (channel) {
        return List.generate(_inputSize, (y) {
          return List.generate(_inputSize, (x) {
            final p = image.getPixel(x, y);
            final value = switch (channel) {
              0 => p.r,
              1 => p.g,
              _ => p.b,
            };
            return (value.toDouble() - 127.5) / 127.5;
          });
        });
      }),
    ];
  }

  List<List<List<List<int>>>> _nhwcInputUint8(img.Image image) {
    return [
      List.generate(_inputSize, (y) {
        return List.generate(_inputSize, (x) {
          final p = image.getPixel(x, y);
          return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
        });
      }),
    ];
  }

  List<List<List<List<int>>>> _nchwInputUint8(img.Image image) {
    return [
      List.generate(3, (channel) {
        return List.generate(_inputSize, (y) {
          return List.generate(_inputSize, (x) {
            final p = image.getPixel(x, y);
            final value = switch (channel) {
              0 => p.r,
              1 => p.g,
              _ => p.b,
            };
            return value.toInt();
          });
        });
      }),
    ];
  }

  List<double> _normalize(List<double> embedding) {
    double sum = 0;
    for (final value in embedding) {
      sum += value * value;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return embedding;
    return embedding.map((value) => value / norm).toList(growable: false);
  }

  dynamic _makeOutputBuffer(List<int> shape) {
    if (shape.isEmpty) return 0.0;
    if (shape.length == 1) return List<double>.filled(shape.first, 0.0);
    return List.generate(
      shape.first,
      (_) => _makeOutputBuffer(shape.sublist(1)),
    );
  }

  List<double> _flattenOutput(dynamic value) {
    final result = <double>[];

    void visit(dynamic node) {
      if (node is num) {
        result.add(node.toDouble());
      } else if (node is Iterable) {
        for (final child in node) {
          visit(child);
        }
      }
    }

    visit(value);
    return result;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _ready = false;
  }
}
