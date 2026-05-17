// Stub for web platform — TFLite (dart:ffi) is not available on web.
import 'dart:typed_data';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class RecognitionResult {
  final bool matched;
  final String? employeeId;
  final double similarity;
  final double euclideanDist;
  const RecognitionResult({
    required this.matched,
    this.employeeId,
    required this.similarity,
    this.euclideanDist = 0,
  });
}

/// Quality filter exception thrown when a frame is rejected before inference.
class QualityFilterException implements Exception {
  final String reason;
  const QualityFilterException(this.reason);
  @override
  String toString() => reason;
}

class FaceRecognitionService {
  static final FaceRecognitionService instance = FaceRecognitionService._();
  FaceRecognitionService._();

  Future<void> init() async {}
  Future<void> dispose() async {}
  Future<List<double>?> extractEmbedding(
    dynamic fullImage,
    dynamic face,
  ) async => null;
  Future<List<double>?> extractEmbeddingFromCrop(dynamic faceImage) async =>
      null;
  dynamic cropFace(dynamic fullImage, dynamic face) => null;
  Future<List<double>?> extractEmbeddingFromNv21({
    required Uint8List nv21Bytes,
    required int width,
    required int height,
    required InputImageRotation rotation,
    required dynamic face,
    bool enforceQuality = true,
  }) async => null;
  RecognitionResult findBestMatch(
    List<double> q,
    Map<String, List<double>> stored,
  ) => const RecognitionResult(matched: false, similarity: 0, euclideanDist: 0);
  RecognitionResult findBestMatchMulti(
    List<double> q,
    Map<String, List<List<double>>> stored,
  ) => const RecognitionResult(matched: false, similarity: 0, euclideanDist: 0);
  static double cosineSimilarity(List<double> a, List<double> b) => 0;
  static double euclideanDistance(List<double> a, List<double> b) => 0;
  static List<double> averageEmbeddings(List<List<double>> e) => [];
  static List<double> bestEmbedding(List<List<double>> e) => [];
  static List<double> normalizeEmbedding(List<double> embedding) =>
      List<double>.from(embedding);
  double get threshold => 0.80;
  bool get isInitialized => false;
}
