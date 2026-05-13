// Web stub for CameraFaceView — camera/mlkit not available on web.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
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

enum LiveFaceDetectionStatus {
  noFace,
  detecting,
  recognized,
  uncertain,
  rejected,
}

class LiveFaceDetectionResult {
  final LiveFaceDetectionStatus status;
  final double similarity;
  final img.Image? fullImage;
  final dynamic inputImage;
  final Uint8List? nv21Bytes;
  final int rawWidth;
  final int rawHeight;
  final InputImageRotation? rotation;
  final dynamic face;
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
    Future<void> Function({
      required img.Image fullImage,
      required dynamic inputImage,
      required Uint8List? nv21Bytes,
      required int rawWidth,
      required int rawHeight,
      required InputImageRotation rotation,
      required dynamic face,
    });

typedef LiveFaceDetectionCallback =
    void Function(LiveFaceDetectionResult result);

class CameraFaceView extends StatefulWidget {
  final bool active;
  final String hint;
  final FaceDetectedCallback? onFaceDetected;
  final VoidCallback? onTimeout;
  final bool liveMode;
  final LiveFaceDetectionCallback? onLiveFaceDetection;

  const CameraFaceView({
    super.key,
    this.active = true,
    this.hint = 'Arahkan wajah ke kamera',
    this.onFaceDetected,
    this.onTimeout,
    this.liveMode = false,
    this.onLiveFaceDetection,
  });

  @override
  State<CameraFaceView> createState() => CameraFaceViewState();
}

class CameraFaceViewState extends State<CameraFaceView> {
  void startScan() {}
  void resetToReady() {}
  void markDone() {}
  Future<void> refreshCamera() async {}
  Future<void> pauseLiveStream() async {}

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.no_photography_outlined,
            size: 40,
            color: AppColors.textSecondary,
          ),
          SizedBox(height: 12),
          Text(
            'Kamera tidak tersedia di browser',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 4),
          Text(
            'Gunakan aplikasi Android untuk absensi wajah',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
