import 'package:screen_brightness/screen_brightness.dart';

/// Paksa kecerahan layar ke maksimum saat kamera aktif,
/// lalu kembalikan ke nilai semula saat selesai.
class ScreenBrightnessService {
  static final ScreenBrightnessService instance = ScreenBrightnessService._();
  ScreenBrightnessService._();

  Future<void> setMax() async {
    try {
      await ScreenBrightness.instance.setScreenBrightness(1.0);
    } catch (_) {
      // Device tidak mendukung - abaikan.
    }
  }

  Future<void> restore() async {
    try {
      await ScreenBrightness.instance.resetScreenBrightness();
    } catch (_) {}
  }
}
