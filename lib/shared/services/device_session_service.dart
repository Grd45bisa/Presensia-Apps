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
  static const _heartbeatInterval = Duration(seconds: 10);
  static const _requestTimeout = Duration(seconds: 10);

  Timer? _timer;
  bool _isChecking = false;

  void start() {
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

  Future<void> _sendHeartbeat() async {
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

      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 404) {
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
