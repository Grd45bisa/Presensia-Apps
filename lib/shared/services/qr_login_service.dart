import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import 'device_binding_service.dart';
import 'supabase_client.dart';

class QrLoginException implements Exception {
  final String message;

  const QrLoginException(this.message);

  @override
  String toString() => message;
}

class QrLoginService {
  static final QrLoginService instance = QrLoginService._();
  QrLoginService._();

  static const _requestTimeout = Duration(seconds: 45);

  static const _defaultBaseUrl = String.fromEnvironment(
    'PRESENSIA_API_BASE_URL',
    defaultValue: 'https://testing.kitapunya.web.id',
  );

  Future<void> loginWithQrPayload(String payload) async {
    final token = _extractToken(payload);
    if (token == null || token.isEmpty) {
      throw const QrLoginException('QR Code tidak berisi token login.');
    }

    final device = await DeviceBindingService.instance.getDeviceInfo();
    late final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$_defaultBaseUrl/api/auth/qr-login'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': token,
              'device_id': device.id,
              'device_name': device.name,
              'platform': device.platform,
              'app_version': '1.0.0',
            }),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw const QrLoginException(
        'Backend terlalu lama merespons QR Login. Pastikan tunnel testing.kitapunya.web.id dan Supabase sedang stabil, lalu coba QR baru.',
      );
    } catch (_) {
      throw const QrLoginException(
        'Tidak bisa terhubung ke backend. Pastikan testing.kitapunya.web.id aktif dan mengarah ke server backend.',
      );
    }

    final data = _decodeResponse(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QrLoginException(
        data['message'] as String? ??
            'QR Login gagal. Pastikan kode masih aktif.',
      );
    }

    final session = data['session'];
    final refreshToken = session is Map ? session['refresh_token'] : null;
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw const QrLoginException('Sesi login dari server tidak lengkap.');
    }

    try {
      await SupabaseClientService.client.auth.setSession(refreshToken);
    } catch (_) {
      throw const QrLoginException(
        'QR valid, tetapi sesi Supabase gagal dibuat. Coba scan QR baru.',
      );
    }
  }

  Map<String, dynamic> _decodeResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  String? _extractToken(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final uri = Uri.tryParse(value);
    final tokenFromQuery = uri?.queryParameters['token'];
    if (tokenFromQuery != null && tokenFromQuery.trim().isNotEmpty) {
      return tokenFromQuery.trim();
    }

    final tokenFromJson = _extractTokenFromJson(value);
    if (tokenFromJson != null) return tokenFromJson;

    return value;
  }

  String? _extractTokenFromJson(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final token = decoded['token'] ?? decoded['qr_token'];
        if (token is String && token.trim().isNotEmpty) {
          return token.trim();
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
