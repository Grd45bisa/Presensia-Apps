import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';

class FaceAiLabScreen extends StatelessWidget {
  const FaceAiLabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Face AI Testing Lab'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Testing lab wajah saat ini tersedia untuk Android/iOS karena '
            'membutuhkan ML Kit dan TFLite native.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
