import 'dart:async';

import 'package:flutter/foundation.dart';

import 'supabase_client.dart';

class AttendanceDevSettings extends ChangeNotifier {
  AttendanceDevSettings._();

  static final AttendanceDevSettings instance = AttendanceDevSettings._();
  static const _syncInterval = Duration(seconds: 15);

  Timer? _syncTimer;
  bool _isSyncing = false;
  bool _requireBlinkForAttendance = false;

  bool get requireBlinkForAttendance => _requireBlinkForAttendance;

  void startDatabaseSync() {
    if (_syncTimer != null) return;
    unawaited(syncFromDatabase());
    _syncTimer = Timer.periodic(_syncInterval, (_) {
      unawaited(syncFromDatabase());
    });
  }

  void stopDatabaseSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _isSyncing = false;
  }

  Future<void> syncFromDatabase() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final data = await SupabaseClientService.client
          .from('app_settings')
          .select('value')
          .eq('key', 'global')
          .maybeSingle();

      final value = data?['value'];
      if (value is Map) {
        final faceSecurity = value['faceSecurity'];
        if (faceSecurity is Map && faceSecurity['requiresBlink'] is bool) {
          _setRequireBlinkForAttendance(faceSecurity['requiresBlink'] as bool);
        }
      }
    } catch (err) {
      debugPrint('[AttendanceDevSettings] Gagal membaca app_settings: $err');
    } finally {
      _isSyncing = false;
    }
  }

  void _setRequireBlinkForAttendance(bool value) {
    if (_requireBlinkForAttendance == value) return;
    _requireBlinkForAttendance = value;
    notifyListeners();
  }
}
