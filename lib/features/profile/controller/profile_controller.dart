import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../shared/models/app_models.dart';
import '../../../shared/services/profile_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/notification_service.dart';
import '../../../shared/services/supabase_client.dart';
import '../../../shared/store/app_store.dart';

enum ProfileActionStatus { idle, loading, success, error }

class ProfileController extends ChangeNotifier {
  ProfileActionStatus _updateStatus = ProfileActionStatus.idle;
  ProfileActionStatus _passwordStatus = ProfileActionStatus.idle;
  String? _errorMessage;
  String? _successMessage;

  ProfileActionStatus get updateStatus => _updateStatus;
  ProfileActionStatus get passwordStatus => _passwordStatus;
  String? get errorMessage => _errorMessage;
  String? get successMessage => _successMessage;

  bool get isUpdating => _updateStatus == ProfileActionStatus.loading;
  bool get isChangingPassword => _passwordStatus == ProfileActionStatus.loading;

  void resetUpdate() {
    _updateStatus = ProfileActionStatus.idle;
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();
  }

  void resetPassword() {
    _passwordStatus = ProfileActionStatus.idle;
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();
  }

  // ─── UPDATE PROFILE ───────────────────────────────────────────────────────

  Future<bool> updateProfile(EmployeeProfile updated) async {
    _updateStatus = ProfileActionStatus.loading;
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();

    try {
      await ProfileService.instance.updateProfile(updated);
      AppStore.instance.setProfile(updated);
      _updateStatus = ProfileActionStatus.success;
      _successMessage = 'Profil berhasil diperbarui.';
      notifyListeners();
      return true;
    } catch (_) {
      _updateStatus = ProfileActionStatus.error;
      _errorMessage = 'Gagal memperbarui profil. Coba lagi.';
      notifyListeners();
      return false;
    }
  }

  // ─── TOGGLE NOTIFICATIONS ─────────────────────────────────────────────────

  Future<void> toggleNotifications({required bool enabled}) async {
    final profile = AppStore.instance.profile;
    if (profile == null) return;
    final updated = profile.copyWith(notificationsEnabled: enabled);
    try {
      await ProfileService.instance.updateProfile(updated);
      AppStore.instance.setProfile(updated);
      // Saat user mengaktifkan notifikasi, minta whitelist battery
      // optimization supaya alarm tidak dibunuh OEM secara agresif.
      if (enabled) {
        _maybeRequestBatteryOptimization();
      }
    } catch (_) {
      // Revert optimistic update
      AppStore.instance.setProfile(profile);
    }
  }

  // ─── REMINDER TIME SETTINGS ───────────────────────────────────────────────

  /// Perbarui jam pengingat (check-in / check-out / tracker). Disimpan ke
  /// work_schedule_settings, lalu pengingat terjadwal langsung di-refresh.
  Future<bool> updateReminderSettings({
    TimeOfDaySetting? checkIn,
    TimeOfDaySetting? checkOut,
    TimeOfDaySetting? tracker,
    bool? reminderEnabled,
  }) async {
    final current = AppStore.instance.settings;
    final next = current.copyWith(
      checkInReminderTime: checkIn,
      checkOutReminderTime: checkOut,
      trackerReminderTime: tracker,
      reminderEnabled: reminderEnabled,
    );
    AppStore.instance.updateSettings(next);
    return true;
  }

  // ─── CHANGE PASSWORD ──────────────────────────────────────────────────────

  Future<bool> changePassword(String newPassword) async {
    _passwordStatus = ProfileActionStatus.loading;
    _errorMessage = null;
    _successMessage = null;
    notifyListeners();

    try {
      await SupabaseClientService.client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
      _passwordStatus = ProfileActionStatus.success;
      _successMessage = 'Password berhasil diubah.';
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _passwordStatus = ProfileActionStatus.error;
      _errorMessage = _mapError(e.message);
      notifyListeners();
      return false;
    } catch (_) {
      _passwordStatus = ProfileActionStatus.error;
      _errorMessage = 'Gagal mengubah password. Coba lagi.';
      notifyListeners();
      return false;
    }
  }

  // ─── SIGN OUT ─────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    AppStore.instance.clear();
    await AuthService.instance.signOut();
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────

  String _mapError(String raw) {
    final msg = raw.toLowerCase();
    if (msg.contains('weak password') || msg.contains('password')) {
      return 'Password minimal 6 karakter.';
    }
    if (msg.contains('network') || msg.contains('socket')) {
      return 'Tidak dapat terhubung. Periksa koneksi Anda.';
    }
    return 'Terjadi kesalahan. Silakan coba lagi.';
  }

  /// Minta user whitelist battery optimization sekali — jangan spam setiap
  /// buka app. Pakai flag SharedPreferences sederhana.
  Future<void> _maybeRequestBatteryOptimization() async {
    try {
      final already = await NotificationService.instance
          .isIgnoringBatteryOptimizations();
      if (!already) {
        await NotificationService.instance
            .requestIgnoreBatteryOptimizations();
      }
    } catch (_) {}
  }
}
