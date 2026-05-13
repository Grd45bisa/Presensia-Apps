import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

/// Result of a quality check on a single camera frame.
class FrameQualityResult {
  final bool accepted;
  final double score; // 0.0 - 1.0, higher = better
  final String? rejectReason;

  const FrameQualityResult({
    required this.accepted,
    required this.score,
    this.rejectReason,
  });
}

/// Stateless utility that scores and filters face frames before embedding
/// extraction. These checks keep low-quality frames out of TFLite inference.
class FaceQualityFilter {
  /// Face bounding-box height must be at least 15% of full frame height.
  static const double _minFaceHeightRatio = 0.15;

  /// Laplacian variance threshold for blur detection.
  static const double _minSharpness = 100.0;

  /// Mean luminance range [0, 255] for the cropped face region.
  static const double _minBrightness = 50.0;
  static const double _maxBrightness = 200.0;

  static const double _maxYawPitchDegrees = 20.0;
  static const double _maxRollDegrees = 15.0;

  /// Decode an image payload and reject it when Laplacian variance is < 100.
  static bool isImageTooBlurry(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return true;
    return _laplacianVariance(image) < _minSharpness;
  }

  /// Accept only face crops with mean brightness in the 50-200 range.
  static bool isLightingAcceptable(img.Image faceCrop) {
    final brightness = _meanBrightness(faceCrop);
    return brightness >= _minBrightness && brightness <= _maxBrightness;
  }

  /// Accept only faces whose bounding-box height is >15% of frame height.
  static bool isFaceSizeAcceptable(Face face, Size frame) {
    if (frame.height <= 0) return false;
    return face.boundingBox.height / frame.height >= _minFaceHeightRatio;
  }

  /// Accept only moderate poses: yaw/pitch <20 degrees and roll <15 degrees.
  static bool isPoseAcceptable(Face face) => _poseRejectReason(face) == null;

  /// Lightweight check for camera streams: no pixel decoding needed.
  static FrameQualityResult evaluateFast(
    Face face,
    int frameWidth,
    int frameHeight,
  ) {
    final frame = Size(frameWidth.toDouble(), frameHeight.toDouble());
    if (!isFaceSizeAcceptable(face, frame)) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Dekatkan wajah ke kamera',
      );
    }

    final poseReject = _poseRejectReason(face);
    if (poseReject != null) return poseReject;

    final faceHeightRatio = face.boundingBox.height / frameHeight;
    final sizeScore = (faceHeightRatio / 0.45).clamp(0.0, 1.0);
    final roll = _rollDegrees(face).abs();
    final poseScore = roll > 0
        ? (1.0 - roll / _maxRollDegrees).clamp(0.0, 1.0)
        : 1.0;
    final score = (sizeScore * 0.6 + poseScore * 0.4).clamp(0.0, 1.0);

    return FrameQualityResult(accepted: true, score: score);
  }

  /// Full evaluate with pixel checks for brightness and blur.
  static FrameQualityResult evaluate(img.Image fullImage, Face face) {
    final frame = Size(fullImage.width.toDouble(), fullImage.height.toDouble());
    if (!isFaceSizeAcceptable(face, frame)) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Dekatkan wajah ke kamera',
      );
    }

    final faceCrop = _faceCrop(fullImage, face);
    final brightness = _meanBrightness(faceCrop);
    if (brightness < _minBrightness) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason:
            'Pencahayaan terlalu gelap. Cari tempat yang lebih terang',
      );
    }
    if (brightness > _maxBrightness) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Pencahayaan terlalu terang. Kurangi cahaya langsung',
      );
    }

    final sharpness = _laplacianVariance(faceCrop);
    if (sharpness < _minSharpness) {
      return FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Gambar terlalu blur (${sharpness.toStringAsFixed(1)})',
      );
    }

    final poseReject = _poseRejectReason(face);
    if (poseReject != null) return poseReject;

    final faceHeightRatio = face.boundingBox.height / fullImage.height;
    final sizeScore = (faceHeightRatio / 0.45).clamp(0.0, 1.0);
    final sharpScore = (sharpness / 300.0).clamp(0.0, 1.0);
    final brightScore = (1.0 - ((brightness - 128.0) / 128.0).abs()).clamp(
      0.0,
      1.0,
    );
    final roll = _rollDegrees(face).abs();
    final poseScore = roll > 0
        ? (1.0 - roll / _maxRollDegrees).clamp(0.0, 1.0)
        : 1.0;

    final score =
        (sizeScore * 0.25 +
                sharpScore * 0.40 +
                brightScore * 0.20 +
                poseScore * 0.15)
            .clamp(0.0, 1.0);

    return FrameQualityResult(accepted: true, score: score);
  }

  static double _meanBrightness(img.Image image) {
    double sum = 0;
    final total = image.width * image.height;
    if (total == 0) return 0;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }
    return sum / total;
  }

  /// Laplacian variance - proxy for sharpness. Higher = sharper.
  static double _laplacianVariance(img.Image image) {
    final shorterSide = image.width < image.height ? image.width : image.height;
    if (shorterSide <= 0) return 0;

    final scale = 64 / shorterSide;
    final small = scale < 1.0
        ? img.copyResize(
            image,
            width: (image.width * scale).round(),
            height: (image.height * scale).round(),
          )
        : image;

    final w = small.width;
    final h = small.height;
    if (w < 3 || h < 3) return 0;

    final gray = List.generate(h, (y) {
      return List.generate(w, (x) {
        final p = small.getPixel(x, y);
        return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      });
    });

    double mean = 0;
    double mean2 = 0;
    int count = 0;
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final lap =
            gray[y - 1][x] +
            gray[y + 1][x] +
            gray[y][x - 1] +
            gray[y][x + 1] -
            4 * gray[y][x];
        mean += lap;
        mean2 += lap * lap;
        count++;
      }
    }
    if (count == 0) return 0;
    mean /= count;
    mean2 /= count;
    return mean2 - mean * mean;
  }

  static double _rollDegrees(Face face) {
    final mlKitRoll = face.headEulerAngleZ;
    if (mlKitRoll != null) return mlKitRoll;

    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    if (leftEye == null || rightEye == null) return 0;

    final dx = (rightEye.position.x - leftEye.position.x).toDouble();
    final dy = (rightEye.position.y - leftEye.position.y).toDouble();
    if (dx == 0 && dy == 0) return 0;
    return math.atan2(dy, dx) * 180.0 / math.pi;
  }

  static img.Image _faceCrop(img.Image fullImage, Face face) {
    final box = face.boundingBox;
    final x = box.left.toInt().clamp(0, fullImage.width - 1);
    final y = box.top.toInt().clamp(0, fullImage.height - 1);
    final w = box.width.toInt().clamp(1, fullImage.width - x);
    final h = box.height.toInt().clamp(1, fullImage.height - y);
    return img.copyCrop(fullImage, x: x, y: y, width: w, height: h);
  }

  static FrameQualityResult? _poseRejectReason(Face face) {
    final yaw = face.headEulerAngleY?.abs();
    if (yaw != null && yaw > _maxYawPitchDegrees) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Hadapkan wajah ke depan',
      );
    }

    final pitch = face.headEulerAngleX?.abs();
    if (pitch != null && pitch > _maxYawPitchDegrees) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Jangan terlalu menunduk atau mendongak',
      );
    }

    if (_rollDegrees(face).abs() > _maxRollDegrees) {
      return const FrameQualityResult(
        accepted: false,
        score: 0,
        rejectReason: 'Jaga kepala tetap tegak',
      );
    }
    return null;
  }
}
