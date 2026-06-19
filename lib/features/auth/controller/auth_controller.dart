import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/device_session_service.dart';
import '../../../shared/services/profile_service.dart';
import '../../../shared/services/supabase_client.dart';

enum AuthStatus { idle, loading, success, error }

class AuthController extends ChangeNotifier {
  AuthStatus _status = AuthStatus.idle;
  String? _errorMessage;

  AuthStatus get status => _status;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _status == AuthStatus.loading;

  void _set(AuthStatus s, [String? err]) {
    _status = s;
    _errorMessage = err;
    notifyListeners();
  }

  void reset() => _set(AuthStatus.idle);

  // ─── SIGN IN ──────────────────────────────────────────────────────────────

  Future<bool> signIn({required String email, required String password}) async {
    _set(AuthStatus.loading);
    AuthResponse response;
    try {
      response = await AuthService.instance.signIn(
        email: email,
        password: password,
      );
    } on AuthException catch (e) {
      _set(AuthStatus.error, _mapAuthError(e.message));
      return false;
    } catch (_) {
      _set(AuthStatus.error, 'Tidak dapat terhubung. Periksa koneksi Anda.');
      return false;
    }

    final user = AuthService.instance.currentUser ?? response.user;
    if (user == null) {
      _set(AuthStatus.error, 'Sesi login tidak valid. Silakan coba lagi.');
      return false;
    }

    try {
      await ProfileService.instance.ensureProfileExists(user);

      // Device guard is disabled by default during development, so any valid
      // Supabase email/password account can stay signed in. Enable it later
      // with --dart-define=PRESENSIA_DEVICE_GUARD_ENABLED=true.
      if (DeviceSessionService.instance.isDeviceGuardEnabled) {
        await DeviceSessionService.instance.registerDevice();
      }
    } catch (_) {
      // Development mode: jangan logout kalau setup profil/device belum siap.
      // Session Supabase tetap valid selama email/password benar.
    }

    _set(AuthStatus.success);
    return true;
  }

  // ─── FORGOT PASSWORD ──────────────────────────────────────────────────────

  Future<bool> sendPasswordReset(String email) async {
    _set(AuthStatus.loading);
    try {
      await SupabaseClientService.client.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: 'facework://reset-password',
      );
      _set(AuthStatus.success);
      return true;
    } on AuthException catch (e) {
      _set(AuthStatus.error, _mapAuthError(e.message));
      return false;
    } catch (_) {
      _set(AuthStatus.error, 'Tidak dapat terhubung. Periksa koneksi Anda.');
      return false;
    }
  }

  // ─── RESET PASSWORD ───────────────────────────────────────────────────────

  Future<bool> updatePassword(String newPassword) async {
    _set(AuthStatus.loading);
    try {
      await SupabaseClientService.client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
      _set(AuthStatus.success);
      return true;
    } on AuthException catch (e) {
      _set(AuthStatus.error, _mapAuthError(e.message));
      return false;
    } catch (_) {
      _set(AuthStatus.error, 'Tidak dapat terhubung. Periksa koneksi Anda.');
      return false;
    }
  }

  // ─── SIGN OUT ─────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    _set(AuthStatus.idle);
  }

  // ─── ERROR MAPPING ────────────────────────────────────────────────────────

  String _mapAuthError(String raw) {
    final msg = raw.toLowerCase();
    if (msg.contains('invalid login') || msg.contains('invalid credentials')) {
      return 'Email atau password salah.';
    }
    if (msg.contains('email not confirmed')) {
      return 'Email belum dikonfirmasi. Cek inbox Anda.';
    }
    if (msg.contains('user not found')) {
      return 'Akun dengan email ini tidak ditemukan.';
    }
    if (msg.contains('too many requests') || msg.contains('rate limit')) {
      return 'Terlalu banyak percobaan. Coba lagi beberapa menit.';
    }
    if (msg.contains('network') || msg.contains('socket')) {
      return 'Tidak dapat terhubung. Periksa koneksi Anda.';
    }
    if (msg.contains('weak password') || msg.contains('password')) {
      return 'Password minimal 6 karakter.';
    }
    return 'Terjadi kesalahan. Silakan coba lagi.';
  }
}
