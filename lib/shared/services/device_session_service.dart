import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'device_binding_service.dart';

class DeviceSessionService {
  DeviceSessionService._();

  static final DeviceSessionService instance = DeviceSessionService._();

  static const _apiBaseUrl = String.fromEnvironment(
    'PRESENSIA_API_BASE_URL',
    defaultValue: 'https://apipre.kitapunya.web.id',
  );
  static const _deviceGuardEnabled = bool.fromEnvironment(
    'PRESENSIA_DEVICE_GUARD_ENABLED',
    defaultValue: false,
  );
  static const _heartbeatInterval = Duration(seconds: 10);
  static const _requestTimeout = Duration(seconds: 10);

  Timer? _timer;
  bool _isChecking = false;

  bool get isDeviceGuardEnabled => _deviceGuardEnabled;

  void start() {
    if (!_deviceGuardEnabled) {
      stop();
      return;
    }
    if (_timer != null) return;
    unawaited(_sendHeartbeat());
    _timer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_sendHeartbeat());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _isChecking = false;
  }

  /// Mendaftarkan device karyawan ke backend setelah login email/password.
  /// Mengikuti logika QR Login: kunci active_device_id supaya heartbeat diterima.
  /// Best-effort: kegagalan tidak membatalkan login (heartbeat yang handle ulang).
  Future<void> registerDevice() async {
    if (!_deviceGuardEnabled) return;

    try {
      final employeeId = AuthService.instance.currentUserId;
      if (employeeId == null) return;

      final device = await DeviceBindingService.instance.getDeviceInfo();
      await http
          .post(
            Uri.parse('$_apiBaseUrl/api/mobile/devices/register'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'employee_id': employeeId,
              'device_id': device.id,
              'device_name': device.name,
              'platform': device.platform,
              'app_version': '1.0.0',
            }),
          )
          .timeout(_requestTimeout);
    } catch (_) {
      // Best-effort. Heartbeat periodik akan mencoba ulang / tetap bekerja.
    }
  }

  Future<void> _sendHeartbeat() async {
    if (!_deviceGuardEnabled) return;
    if (_isChecking || !AuthService.instance.isSignedIn) return;

    _isChecking = true;
    try {
      final employeeId = AuthService.instance.currentUserId;
      if (employeeId == null) return;

      final device = await DeviceBindingService.instance.getDeviceInfo();
      final response = await http
          .post(
            Uri.parse('$_apiBaseUrl/api/mobile/devices/heartbeat'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'employee_id': employeeId,
              'device_id': device.id,
              'device_name': device.name,
              'platform': device.platform,
              'app_version': '1.0.0',
            }),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        // Device belum terdaftar (mis. mock mode atau binding hilang).
        // Coba daftarkan ulang; hanya logout jika register juga gagal.
        await registerDevice();
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        // Akses dicabut admin: logout valid.
        await _forceLogout();
      }
    } catch (_) {
      // Jangan logout hanya karena koneksi backend sementara gagal.
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _forceLogout() async {
    stop();
    await AuthService.instance.signOut();
  }
}
