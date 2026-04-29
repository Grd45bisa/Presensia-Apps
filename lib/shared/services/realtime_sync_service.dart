import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/app_models.dart';
import '../providers/notification_provider.dart';
import '../store/app_store.dart';
import 'supabase_client.dart';

/// Subscribes to all relevant Supabase tables via Realtime and patches
/// AppStore in-place so every listening widget rebuilds automatically.
class RealtimeSyncService {
  static final RealtimeSyncService instance = RealtimeSyncService._();
  RealtimeSyncService._();

  RealtimeChannel? _channel;
  String? _subscribedUserId;

  SupabaseClient get _db => SupabaseClientService.client;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Call after login / session restore. Safe to call multiple times.
  void subscribe(String userId) {
    if (_subscribedUserId == userId && _channel != null) return;
    unsubscribe();
    _subscribedUserId = userId;

    _channel = _db
        .channel('app_sync_$userId')
        // ── attendance_records ──────────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onAttendanceChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onAttendanceChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'attendance_records',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onAttendanceDelete(payload),
        )
        // ── worklog_entries ─────────────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'worklog_entries',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onWorklogChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'worklog_entries',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onWorklogChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'worklog_entries',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onWorklogDelete(payload),
        )
        // ── reminder_events ─────────────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'reminder_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onReminderChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'reminder_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onReminderChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'reminder_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onReminderDelete(payload),
        )
        // ── work_schedule_settings ──────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'work_schedule_settings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onSettingsChange(payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'work_schedule_settings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (payload) => _onSettingsChange(payload),
        )
        // ── profiles ────────────────────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (payload) => _onProfileChange(payload),
        )
        // ── projects ────────────────────────────────────────────────────────
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'projects',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (_) => _onProjectsChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'projects',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (_) => _onProjectsChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'projects',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'employee_id',
            value: userId,
          ),
          callback: (_) => _onProjectsChanged(),
        )
        .subscribe();
  }

  void unsubscribe() {
    if (_channel != null) {
      _db.removeChannel(_channel!);
      _channel = null;
    }
    _subscribedUserId = null;
  }

  // ── Handlers ───────────────────────────────────────────────────────────────

  void _scheduleOnUiThread(VoidCallback fn) {
    SchedulerBinding.instance.addPostFrameCallback((_) => fn());
  }

  void _onAttendanceChange(PostgresChangePayload payload) {
    try {
      final record = AttendanceRecord.fromJson(
        Map<String, dynamic>.from(payload.newRecord),
      );
      _scheduleOnUiThread(() {
        AppStore.instance.setAttendance(record);
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onAttendanceDelete(PostgresChangePayload payload) {
    try {
      final old = payload.oldRecord;
      final dateStr = old['date'] as String?;
      if (dateStr == null) return;
      final date = DateTime.parse(dateStr);
      _scheduleOnUiThread(() {
        AppStore.instance.removeAttendance(date);
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onWorklogChange(PostgresChangePayload payload) {
    try {
      final entry = WorklogEntry.fromJson(
        Map<String, dynamic>.from(payload.newRecord),
      );
      _scheduleOnUiThread(() {
        AppStore.instance.upsertWorklog(entry);
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onWorklogDelete(PostgresChangePayload payload) {
    try {
      final id = payload.oldRecord['id'] as String?;
      if (id == null) return;
      _scheduleOnUiThread(() {
        AppStore.instance.removeWorklog(id);
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onReminderChange(PostgresChangePayload payload) {
    try {
      final event = ReminderEvent.fromJson(
        Map<String, dynamic>.from(payload.newRecord),
      );
      _scheduleOnUiThread(() {
        final existing = AppStore.instance
            .remindersOf(event.startDateTime)
            .any((r) => r.id == event.id);
        if (existing) {
          AppStore.instance.updateReminder(event);
        } else {
          AppStore.instance.addReminder(event);
        }
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onReminderDelete(PostgresChangePayload payload) {
    try {
      final old = payload.oldRecord;
      final id = old['id'] as String?;
      final startStr = old['start_datetime'] as String?;
      if (id == null || startStr == null) return;
      final startDt = DateTime.parse(startStr).toLocal();
      _scheduleOnUiThread(() {
        final reminders = AppStore.instance.remindersOf(startDt);
        final match = reminders.where((r) => r.id == id).firstOrNull;
        if (match != null) {
          AppStore.instance.removeReminder(match);
          NotificationProvider.instance.refresh();
        }
      });
    } catch (_) {}
  }

  void _onSettingsChange(PostgresChangePayload payload) {
    try {
      final settings = WorkScheduleSettings.fromJson(
        Map<String, dynamic>.from(payload.newRecord),
      );
      _scheduleOnUiThread(() {
        AppStore.instance.applyRemoteSettings(settings);
        NotificationProvider.instance.refresh();
      });
    } catch (_) {}
  }

  void _onProfileChange(PostgresChangePayload payload) {
    try {
      final profile = EmployeeProfile.fromJson(
        Map<String, dynamic>.from(payload.newRecord),
      );
      _scheduleOnUiThread(() {
        AppStore.instance.setProfile(profile);
      });
    } catch (_) {}
  }

  void _onProjectsChanged() {
    _scheduleOnUiThread(() {
      AppStore.instance.notifyProjectsChanged();
    });
  }
}
