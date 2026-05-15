import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_quality_filter.dart';

/// Result of a recognition attempt, carrying both similarity metrics for debug.
class RecognitionResult {
  final bool matched;
  final String? employeeId;
  final double similarity; // cosine similarity [0, 1]
  final double euclideanDist; // euclidean distance (lower = more similar)

  const RecognitionResult({
    required this.matched,
    this.employeeId,
    required this.similarity,
    this.euclideanDist = 0,
  });
}

/// Thrown when a camera frame fails pre-inference quality checks.
/// The [reason] is a localised Indonesian string suitable for snackbar display.
class QualityFilterException implements Exception {
  final String reason;
  const QualityFilterException(this.reason);
  @override
  String toString() => reason;
}

/// MobileFaceNet pipeline:
///   Camera frame → MLKit detection → alignment → model-size crop → TFLite → L2-normalized embedding
///   Matching: cosine similarity (primary) + euclidean distance (debug)
class FaceRecognitionService {
  static final FaceRecognitionService instance = FaceRecognitionService._();
  FaceRecognitionService._();

  Interpreter? _interpreter;
  bool _initialized = false;

  static const String _modelAsset = 'assets/models/mobilefacenet.tflite';

  // Cosine similarity threshold for L2-normalized face embeddings.
  // Tune this with real attendance samples if false accepts/rejects shift.
  static const double _cosineThreshold = 0.93;

  int _inputSize = 0;
  int _embeddingSize = 0;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialized) return;
    _interpreter = await Interpreter.fromAsset(_modelAsset);
    // ignore: avoid_print
    print('[FaceRec] input shape: ${_interpreter!.getInputTensor(0).shape}');
    // ignore: avoid_print
    print('[FaceRec] output shape: ${_interpreter!.getOutputTensor(0).shape}');
    _configureModelShape();
    _initialized = true;
    try {
      _validateInferenceOutput();
    } catch (_) {
      _initialized = false;
      rethrow;
    }
  }

  void _configureModelShape() {
    final inputShape = _interpreter!.getInputTensor(0).shape;
    if (inputShape.length != 4 || inputShape[0] != 1 || inputShape[3] != 3) {
      throw StateError(
        'Unexpected face recognition input shape: $inputShape. '
        'Expected [1, H, W, 3].',
      );
    }
    if (inputShape[1] != inputShape[2]) {
      throw StateError('Non-square model input not supported: $inputShape.');
    }
    _inputSize = inputShape[1];

    final outputShape = _interpreter!.getOutputTensor(0).shape;
    if (outputShape.length != 2 ||
        outputShape.first != 1 ||
        outputShape[1] <= 0) {
      throw StateError(
        'Unexpected face recognition output shape: $outputShape. '
        'Expected [1, embedding_size]. Check that $_modelAsset is an '
        'embedding model, not a detector model.',
      );
    }
    _embeddingSize = outputShape[1];

    // ignore: avoid_print
    print(
      '[FaceRec] Model loaded - input: [1, $_inputSize, $_inputSize, 3], '
      'output: [1, $_embeddingSize]',
    );
  }

  void _validateInferenceOutput() {
    final blank = img.Image(width: _inputSize, height: _inputSize);
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        blank.setPixelRgb(x, y, 128, 128, 128);
      }
    }

    final embedding = _runInference(blank);
    if (embedding.length != _embeddingSize) {
      throw StateError(
        'Face recognition inference output length mismatch: ${embedding.length}. '
        'Expected $_embeddingSize.',
      );
    }
  }

  Future<void> dispose() async {
    _interpreter?.close();
    _interpreter = null;
    _initialized = false;
  }

  // ── Embedding extraction ──────────────────────────────────────────────────

  /// Extract embedding from a decoded still image + MLKit face object.
  /// Used by enrollment (high-res JPEG) and attendance still-capture fallback.
  Future<List<double>?> extractEmbedding(img.Image fullImage, Face face) async {
    if (!_initialized) await init();

    final quality = FaceQualityFilter.evaluate(fullImage, face);
    if (!quality.accepted) {
      // ignore: avoid_print
      print('[FaceRec] Quality rejected: ${quality.rejectReason}');
      throw QualityFilterException(
        quality.rejectReason ?? 'Kualitas wajah buruk',
      );
    }

    final cropped = cropFace(fullImage, face);
    if (cropped == null) return null;
    return extractEmbeddingFromCrop(cropped);
  }

  /// Extract embedding from an already-cropped face image (any size → resized internally).
  Future<List<double>?> extractEmbeddingFromCrop(img.Image faceImage) async {
    if (!_initialized) await init();
    final resized = img.copyResize(
      faceImage,
      width: _inputSize,
      height: _inputSize,
    );
    return _runInference(resized);
  }

  img.Image? cropFace(img.Image fullImage, Face face) {
    final box = face.boundingBox;
    final left = box.left.toInt().clamp(0, fullImage.width - 1);
    final top = box.top.toInt().clamp(0, fullImage.height - 1);
    final right = box.right.toInt().clamp(left + 1, fullImage.width);
    final bottom = box.bottom.toInt().clamp(top + 1, fullImage.height);
    final width = right - left;
    final height = bottom - top;
    if (width <= 10 || height <= 10) return null;

    return img.copyCrop(
      fullImage,
      x: left,
      y: top,
      width: width,
      height: height,
    );
  }

  /// Extract embedding from NV21 bytes by decoding ONLY the face crop region.
  /// Heavy work (NV21 decode + TFLite) runs in a background isolate via compute().
  Future<List<double>?> extractEmbeddingFromNv21({
    required Uint8List nv21Bytes,
    required int width,
    required int height,
    required InputImageRotation rotation,
    required Face face,
  }) async {
    if (!_initialized) await init();

    final quality = FaceQualityFilter.evaluateFast(face, width, height);
    if (!quality.accepted) {
      // ignore: avoid_print
      print('[FaceRec] Quality rejected: ${quality.rejectReason}');
      throw QualityFilterException(
        quality.rejectReason ?? 'Kualitas wajah buruk',
      );
    }

    // Compute the padded crop region in the original (pre-rotation) NV21 space.
    // We decode only this region instead of the full multi-megapixel frame.
    final box = face.boundingBox;
    final padding = (box.width * 0.5).toInt();
    final cropX = (box.left - padding).clamp(0, width - 1).toInt();
    final cropY = (box.top - padding).clamp(0, height - 1).toInt();
    final cropW = (box.width + padding * 2).clamp(1, width - cropX).toInt();
    final cropH = (box.height + padding * 2).clamp(1, height - cropY).toInt();

    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];

    // Decode only the crop region from NV21 in a background isolate,
    // passing eye landmarks so alignment matches the enrollment pipeline.
    final faceImage = await compute(
      _nv21CropToImage,
      _NV21CropParams(
        nv21: nv21Bytes,
        frameWidth: width,
        frameHeight: height,
        cropX: cropX,
        cropY: cropY,
        cropW: cropW,
        cropH: cropH,
        rotation: rotation,
        leX: leftEye?.position.x.toDouble(),
        leY: leftEye?.position.y.toDouble(),
        reX: rightEye?.position.x.toDouble(),
        reY: rightEye?.position.y.toDouble(),
        inputSize: _inputSize,
      ),
    );

    if (faceImage == null) return null;
    return _runInference(faceImage);
  }

  // ── Top-level function for compute() ──────────────────────────────────────
  // Runs in a background isolate: decode crop from NV21, apply rotation,
  // then eye-anchor align (same pipeline as enrollment) → resize to model input.

  static img.Image? _nv21CropToImage(_NV21CropParams p) {
    // 1. Decode only the padded bounding-box region from NV21.
    final ySize = p.frameWidth * p.frameHeight;
    final raw = img.Image(width: p.cropW, height: p.cropH);

    for (int cy = 0; cy < p.cropH; cy++) {
      final fy = p.cropY + cy;
      for (int cx = 0; cx < p.cropW; cx++) {
        final fx = p.cropX + cx;
        final yIndex = fy * p.frameWidth + fx;
        final uvIndex = ySize + (fy >> 1) * p.frameWidth + (fx & ~1);
        if (yIndex >= ySize || uvIndex + 1 >= p.nv21.length) continue;

        final yVal = p.nv21[yIndex];
        final vVal = p.nv21[uvIndex];
        final uVal = p.nv21[uvIndex + 1];

        final r = (yVal + 1.370705 * (vVal - 128)).round().clamp(0, 255);
        final g = (yVal - 0.698001 * (vVal - 128) - 0.337633 * (uVal - 128))
            .round()
            .clamp(0, 255);
        final b = (yVal + 1.732446 * (uVal - 128)).round().clamp(0, 255);
        raw.setPixelRgb(cx, cy, r, g, b);
      }
    }

    // 2. Apply sensor rotation to the crop.
    final img.Image rotated;
    switch (p.rotation) {
      case InputImageRotation.rotation90deg:
        rotated = img.copyRotate(raw, angle: 90);
      case InputImageRotation.rotation180deg:
        rotated = img.copyRotate(raw, angle: 180);
      case InputImageRotation.rotation270deg:
        rotated = img.copyRotate(raw, angle: 270);
      case InputImageRotation.rotation0deg:
        rotated = raw;
    }

    // 3. Eye-anchor alignment using landmark coordinates mapped into crop space.
    //    Landmark positions from MLKit are in full-frame coordinates — subtract
    //    the crop origin so they map correctly into the decoded sub-image.
    if (p.leX != null && p.leY != null && p.reX != null && p.reY != null) {
      // Transform landmark to crop-local coordinates, then apply the same
      // rotation we applied to the image pixels.
      double mapX(double fx, double fy) {
        final cx2 = fx - p.cropX;
        final cy2 = fy - p.cropY;
        switch (p.rotation) {
          case InputImageRotation.rotation90deg:
            return (p.cropH - 1) - cy2;
          case InputImageRotation.rotation180deg:
            return (p.cropW - 1) - cx2;
          case InputImageRotation.rotation270deg:
            return cy2.toDouble();
          case InputImageRotation.rotation0deg:
            return cx2.toDouble();
        }
      }

      double mapY(double fx, double fy) {
        final cx2 = fx - p.cropX;
        final cy2 = fy - p.cropY;
        switch (p.rotation) {
          case InputImageRotation.rotation90deg:
            return cx2.toDouble();
          case InputImageRotation.rotation180deg:
            return (p.cropH - 1) - cy2;
          case InputImageRotation.rotation270deg:
            return (p.cropW - 1) - cx2;
          case InputImageRotation.rotation0deg:
            return cy2.toDouble();
        }
      }

      final leXr = mapX(p.leX!, p.leY!);
      final leYr = mapY(p.leX!, p.leY!);
      final reXr = mapX(p.reX!, p.reY!);
      final reYr = mapY(p.reX!, p.reY!);

      final dx = reXr - leXr;
      final dy = reYr - leYr;
      final angle = math.atan2(dy, dx) * 180 / math.pi;

      final aligned = angle.abs() > 1.0
          ? img.copyRotate(rotated, angle: -angle)
          : rotated;

      final cosA = math.cos(-angle * math.pi / 180);
      final sinA = math.sin(-angle * math.pi / 180);
      final imgCx = rotated.width / 2.0;
      final imgCy = rotated.height / 2.0;

      double rot(double px, double py, bool isX) {
        final rx = cosA * (px - imgCx) - sinA * (py - imgCy) + imgCx;
        final ry = sinA * (px - imgCx) + cosA * (py - imgCy) + imgCy;
        return isX ? rx : ry;
      }

      final mX = (rot(leXr, leYr, true) + rot(reXr, reYr, true)) / 2.0;
      final mY = (rot(leXr, leYr, false) + rot(reXr, reYr, false)) / 2.0;
      final eyeDist = (rot(reXr, reYr, true) - rot(leXr, leYr, true)).abs();

      if (eyeDist >= 4) {
        final cropSize = (eyeDist * 3.5).round();
        final x = (mX - cropSize / 2.0).round().clamp(0, aligned.width - 1);
        final y = (mY - cropSize * 0.38).round().clamp(0, aligned.height - 1);
        final w = cropSize.clamp(1, aligned.width - x);
        final h = cropSize.clamp(1, aligned.height - y);
        if (w >= 20 && h >= 20) {
          final face = img.copyCrop(aligned, x: x, y: y, width: w, height: h);
          return img.copyResize(face, width: p.inputSize, height: p.inputSize);
        }
      }
    }

    // 4. Fallback: just resize the rotated crop directly.
    return img.copyResize(rotated, width: p.inputSize, height: p.inputSize);
  }

  // ── Alignment & crop ──────────────────────────────────────────────────────

  /// Align and crop the face to the configured model input size for inference.
  ///
  /// Strategy (eye-anchor):
  /// 1. If both eye landmarks are available, rotate the full image so the
  ///    eye line is horizontal, then derive the crop region from the eye
  ///    midpoint with a fixed scale relative to eye distance.
  ///    This makes the crop position invariant to small head tilts and
  ///    distance changes — the #1 cause of embedding instability.
  /// 2. If landmarks are absent, fall back to the bounding-box crop with
  ///    40% padding (generous enough for MobileFaceNet).
  List<double> _runInference(img.Image faceImage) {
    if (faceImage.width != _inputSize || faceImage.height != _inputSize) {
      throw StateError(
        'Unexpected face recognition image size: '
        '${faceImage.width}x${faceImage.height}. '
        'Expected ${_inputSize}x$_inputSize.',
      );
    }

    // MobileFaceNet: NHWC float32, RGB, normalized to [-1, 1]
    final Float32List flatInput = Float32List(_inputSize * _inputSize * 3);
    int idx = 0;
    for (int y = 0; y < _inputSize; y++) {
      for (int x = 0; x < _inputSize; x++) {
        final p = faceImage.getPixel(x, y);
        flatInput[idx++] = (p.r.toDouble() - 127.5) / 127.5;
        flatInput[idx++] = (p.g.toDouble() - 127.5) / 127.5;
        flatInput[idx++] = (p.b.toDouble() - 127.5) / 127.5;
      }
    }

    // reshape() is a List extension from tflite_flutter, not on Float32List
    final input = flatInput.toList().reshape([1, _inputSize, _inputSize, 3]);
    final output = [List.filled(_embeddingSize, 0.0)];

    final stopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    _interpreter!.run(input, output);
    if (stopwatch != null) {
      stopwatch.stop();
      // ignore: avoid_print
      print('[FaceRec] inference: ${stopwatch.elapsedMilliseconds} ms');
    }

    final embedding = (output[0] as List)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    return _normalizeEmbedding(embedding);
  }

  // ── Matching ──────────────────────────────────────────────────────────────

  /// Compare query embedding against stored embeddings.
  /// Returns cosine similarity as primary metric; euclidean distance for debug.
  RecognitionResult findBestMatch(
    List<double> queryEmbedding,
    Map<String, List<double>> storedEmbeddings,
  ) {
    if (storedEmbeddings.isEmpty) {
      return const RecognitionResult(
        matched: false,
        similarity: 0,
        euclideanDist: 0,
      );
    }

    String? bestId;
    double bestSimilarity = -1.0;
    double bestEuclidean = double.infinity;

    for (final entry in storedEmbeddings.entries) {
      final sim = cosineSimilarity(queryEmbedding, entry.value);
      if (sim > bestSimilarity) {
        bestSimilarity = sim;
        bestEuclidean = euclideanDistance(queryEmbedding, entry.value);
        bestId = entry.key;
      }
    }

    final matched = bestSimilarity >= _cosineThreshold;

    // ignore: avoid_print
    print(
      '[FaceRec] similarity=${bestSimilarity.toStringAsFixed(4)}  '
      'euclidean=${bestEuclidean.toStringAsFixed(4)}  '
      'matched=$matched  threshold=$_cosineThreshold',
    );

    return RecognitionResult(
      matched: matched,
      employeeId: matched ? bestId : null,
      similarity: bestSimilarity,
      euclideanDist: bestEuclidean,
    );
  }

  /// Multi-pose matcher: each employee has a list of stored embeddings
  /// (one per enrollment pose). For each employee we take the BEST cosine
  /// similarity across their poses, then pick the employee with the highest
  /// best-pose score. This is dramatically more robust than averaging
  /// embeddings across poses, because head rotation moves the embedding in
  /// non-linear ways and the average is rarely close to any pose.
  RecognitionResult findBestMatchMulti(
    List<double> queryEmbedding,
    Map<String, List<List<double>>> storedEmbeddings,
  ) {
    if (storedEmbeddings.isEmpty) {
      return const RecognitionResult(
        matched: false,
        similarity: 0,
        euclideanDist: 0,
      );
    }

    String? bestId;
    double bestSimilarity = -1.0;
    double bestEuclidean = double.infinity;

    for (final entry in storedEmbeddings.entries) {
      double localBestSim = -1.0;
      double localBestEuc = double.infinity;
      for (final stored in entry.value) {
        final sim = cosineSimilarity(queryEmbedding, stored);
        if (sim > localBestSim) {
          localBestSim = sim;
          localBestEuc = euclideanDistance(queryEmbedding, stored);
        }
      }
      if (localBestSim > bestSimilarity) {
        bestSimilarity = localBestSim;
        bestEuclidean = localBestEuc;
        bestId = entry.key;
      }
    }

    final matched = bestSimilarity >= _cosineThreshold;

    // ignore: avoid_print
    print(
      '[FaceRec] multi similarity=${bestSimilarity.toStringAsFixed(4)}  '
      'euclidean=${bestEuclidean.toStringAsFixed(4)}  '
      'matched=$matched  threshold=$_cosineThreshold',
    );

    return RecognitionResult(
      matched: matched,
      employeeId: matched ? bestId : null,
      similarity: bestSimilarity,
      euclideanDist: bestEuclidean,
    );
  }

  // ── Static helpers ────────────────────────────────────────────────────────

  static double euclideanDistance(List<double> a, List<double> b) {
    assert(
      a.length == b.length,
      'Embedding mismatch: ${a.length} != ${b.length}',
    );
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    assert(
      a.length == b.length,
      'Embedding mismatch: ${a.length} != ${b.length}',
    );
    double dot = 0;
    double normA = 0;
    double normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = math.sqrt(normA) * math.sqrt(normB);
    if (denom == 0) return 0;
    return (dot / denom).clamp(-1.0, 1.0);
  }

  /// Average multiple embeddings then L2-normalize.
  /// Kept for backward-compatible callers; multi-pose matching compares each
  /// stored pose directly instead of averaging them.
  static List<double> averageEmbeddings(List<List<double>> embeddings) {
    assert(embeddings.isNotEmpty);
    final size = embeddings.first.length;
    final avg = List.filled(size, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < size; i++) {
        avg[i] += e[i];
      }
    }
    for (int i = 0; i < size; i++) {
      avg[i] /= embeddings.length;
    }
    return _normalizeEmbedding(avg);
  }

  /// Select the embedding with the highest L2 norm before normalization —
  /// a proxy for "most confident" model output.
  static List<double> bestEmbedding(List<List<double>> embeddings) {
    assert(embeddings.isNotEmpty);
    // embeddings here are already normalized (norm ≈ 1), so pick by
    // cosine similarity to the group centroid (most representative sample).
    final centroid = averageEmbeddings(embeddings);
    List<double>? best;
    double bestSim = -1;
    for (final e in embeddings) {
      final sim = cosineSimilarity(e, centroid);
      if (sim > bestSim) {
        bestSim = sim;
        best = e;
      }
    }
    return best!;
  }

  static List<double> normalizeEmbedding(List<double> embedding) =>
      _normalizeEmbedding(embedding);

  static List<double> _normalizeEmbedding(List<double> v) {
    double norm = 0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return List<double>.from(v);
    return v.map((x) => x / norm).toList(growable: false);
  }

  double get threshold => _cosineThreshold;
  bool get isInitialized => _initialized;
}

class _NV21CropParams {
  final Uint8List nv21;
  final int frameWidth;
  final int frameHeight;
  final int cropX;
  final int cropY;
  final int cropW;
  final int cropH;
  final InputImageRotation rotation;
  final int inputSize;
  // Eye landmark positions in full-frame coordinates (nullable — fallback to bbox).
  final double? leX;
  final double? leY;
  final double? reX;
  final double? reY;

  const _NV21CropParams({
    required this.nv21,
    required this.frameWidth,
    required this.frameHeight,
    required this.cropX,
    required this.cropY,
    required this.cropW,
    required this.cropH,
    required this.rotation,
    required this.inputSize,
    this.leX,
    this.leY,
    this.reX,
    this.reY,
  });
}
