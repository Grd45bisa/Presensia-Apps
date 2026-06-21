import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../database/session_cache_db.dart';
import '../models/app_models.dart';
import '../services/attendance_service.dart';
import '../services/worklog_service.dart';
import '../services/reminder_service.dart';
import '../services/holiday_service.dart';
import '../services/schedule_settings_service.dart';
import '../services/profile_service.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';

class AppStore extends ChangeNotifier {
  static final AppStore instance = AppStore._();
  AppStore._();

  static const Duration _cloudLoadTimeout = Duration(seconds: 8);

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.transientCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) super.notifyListeners();
      });
    } else {
      super.notifyListeners();
    }
  }

  // ─── PROFILE ──────────────────────────────────────────────────────────────

  EmployeeProfile? _profile;
  EmployeeProfile? get profile => _profile;

  void setProfile(EmployeeProfile profile) {
    _profile = profile;
    notifyListeners();
    _refreshBackgroundReminders();
  }

  // ─── SETTINGS ─────────────────────────────────────────────────────────────

  WorkScheduleSettings _settings = WorkScheduleSettings.defaults();
  WorkScheduleSettings get settings => _settings;

  void updateSettings(WorkScheduleSettings s) {
    _settings = s;
    notifyListeners();
    _persistSettings();
    _refreshBackgroundReminders();
  }

  /// Apply settings that already came from the DB (no re-persist needed).
  void applyRemoteSettings(WorkScheduleSettings s) {
    _settings = s;
    notifyListeners();
    _refreshBackgroundReminders();
  }

  /// Signal that the projects list changed (realtime event).
  void notifyProjectsChanged() => notifyListeners();

  Future<void> _persistSettings() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    await ScheduleSettingsService.instance.saveSettings(uid, _settings);
  }

  // ─── ATTENDANCE ───────────────────────────────────────────────────────────

  final Map<String, AttendanceRecord> _attendance = {};

  static String dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  AttendanceRecord? attendanceOf(DateTime d) => _attendance[dateKey(d)];

  Map<String, AttendanceRecord> get allAttendance =>
      Map.unmodifiable(_attendance);

  void setAttendance(AttendanceRecord record) {
    _attendance[dateKey(record.date)] = record;
    notifyListeners();
    _refreshBackgroundReminders();
    // Jika sudah check-in, batalkan pengingat "belum check-in" hari itu;
    // jika sudah check-out, batalkan juga pengingat check-out.
    NotificationService.instance.cancelAttendanceRemindersFor(record.date);
  }

  void removeAttendance(DateTime date) {
    _attendance.remove(dateKey(date));
    notifyListeners();
    _refreshBackgroundReminders();
  }

  // ─── WORKLOGS ─────────────────────────────────────────────────────────────

  final Map<String, List<WorklogEntry>> _worklogs = {};

  List<WorklogEntry> worklogsOf(DateTime d) =>
      List.unmodifiable(_worklogs[dateKey(d)] ?? []);

  Map<String, List<WorklogEntry>> get allWorklogs => Map.unmodifiable(
    _worklogs.map(
      (key, value) => MapEntry(key, List<WorklogEntry>.unmodifiable(value)),
    ),
  );

  void addWorklog(WorklogEntry entry) {
    final key = dateKey(entry.date);
    final wasEmpty = (_worklogs[key] ?? const []).isEmpty;
    _worklogs[key] = [...(_worklogs[key] ?? []), entry];
    notifyListeners();
    _refreshBackgroundReminders();
    // Begitu ada minimal satu worklog hari itu, batalkan pengingat
    // "tracker belum diisi" supaya tidak muncul basi.
    if (wasEmpty) {
      NotificationService.instance.cancelTrackerReminderFor(entry.date);
    }
  }

  void upsertWorklog(WorklogEntry entry) {
    for (final key in _worklogs.keys.toList()) {
      final filtered = _worklogs[key]!.where((e) => e.id != entry.id).toList();
      if (filtered.length != _worklogs[key]!.length) {
        if (filtered.isEmpty) {
          _worklogs.remove(key);
        } else {
          _worklogs[key] = filtered;
        }
      }
    }
    final key = dateKey(entry.date);
    _worklogs[key] = [...(_worklogs[key] ?? []), entry];
    notifyListeners();
    _refreshBackgroundReminders();
  }

  void setWorklogsForDay(DateTime date, List<WorklogEntry> entries) {
    _worklogs[dateKey(date)] = entries;
    notifyListeners();
    _refreshBackgroundReminders();
  }

  void removeWorklog(String id) {
    var changed = false;
    for (final key in _worklogs.keys.toList()) {
      final filtered = _worklogs[key]!.where((e) => e.id != id).toList();
      if (filtered.length != _worklogs[key]!.length) {
        changed = true;
        if (filtered.isEmpty) {
          _worklogs.remove(key);
        } else {
          _worklogs[key] = filtered;
        }
      }
    }
    if (changed) {
      notifyListeners();
      _refreshBackgroundReminders();
    }
  }

  // ─── REMINDERS ────────────────────────────────────────────────────────────

  final Map<String, List<ReminderEvent>> _reminders = {};

  List<ReminderEvent> remindersOf(DateTime d) =>
      List.unmodifiable(_reminders[dateKey(d)] ?? []);

  void addReminder(ReminderEvent event) {
    final key = dateKey(event.startDateTime);
    _reminders[key] = [...(_reminders[key] ?? []), event];
    notifyListeners();
    NotificationService.instance.scheduleReminder(event);
  }

  void updateReminder(ReminderEvent event) {
    String? existingKey;
    ReminderEvent? existingEvent;

    for (final entry in _reminders.entries) {
      for (final reminder in entry.value) {
        if (reminder.id != event.id) continue;
        existingKey = entry.key;
        existingEvent = reminder;
        break;
      }
      if (existingEvent != null) break;
    }

    final newKey = dateKey(event.startDateTime);
    if (existingKey != null) {
      _reminders[existingKey] = (_reminders[existingKey] ?? [])
          .where((e) => e.id != event.id)
          .toList();
      if ((_reminders[existingKey] ?? const []).isEmpty) {
        _reminders.remove(existingKey);
      }
    }

    _reminders[newKey] = [...(_reminders[newKey] ?? []), event]
      ..sort((a, b) => a.startDateTime.compareTo(b.startDateTime));

    notifyListeners();

    if (existingEvent != null) {
      NotificationService.instance.cancelReminder(existingEvent);
    }
    NotificationService.instance.scheduleReminder(event);
  }

  void removeReminder(ReminderEvent event) {
    final key = dateKey(event.startDateTime);
    _reminders[key] = (_reminders[key] ?? [])
        .where((e) => e.id != event.id)
        .toList();
    notifyListeners();
    NotificationService.instance.cancelReminder(event);
  }

  // ─── SESSION CACHE ────────────────────────────────────────────────────────

  /// Load cached data from SQLite into memory. Returns true if any cache
  /// was loaded. Called before loadFromCloud() for instant UI.
  Future<bool> loadFromCache() async {
    try {
      final cached = await SessionCacheDb.instance.loadAll();
      if (cached.profile == null) return false;

      _profile = cached.profile;
      if (cached.settings != null) {
        _settings = cached.settings!;
      }

      _attendance.clear();
      _attendance.addAll(cached.attendance);

      _worklogs.clear();
      _worklogs.addAll(cached.worklogs);

      _reminders.clear();
      _reminders.addAll(cached.reminders);

      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Persist current in-memory state to SQLite session cache.
  /// Called when the app is about to be terminated.
  Future<void> saveToCache() async {
    final p = _profile;
    if (p == null) return;

    try {
      await SessionCacheDb.instance.saveAll(
        profile: p,
        settings: _settings,
        attendance: Map.from(_attendance),
        worklogs: _worklogs.map((k, v) => MapEntry(k, List.from(v))),
        reminders: _reminders.map((k, v) => MapEntry(k, List.from(v))),
      );
    } catch (_) {
      // Best-effort — don't let cache failures crash the app.
    }
  }

  // ─── CLOUD LOAD ───────────────────────────────────────────────────────────

  bool _loading = false;
  bool get isLoading => _loading;

  /// Called once after login. Loads profile, settings, and current-month data.
  Future<void> loadFromCloud() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;

    _loading = true;
    notifyListeners();

    try {
      final now = DateTime.now();

      final results = await Future.wait([
        ProfileService.instance.ensureProfileExists(
          AuthService.instance.currentUser!,
        ),
        ScheduleSettingsService.instance.fetchSettings(uid),
        AttendanceService.instance.fetchMonthRecords(uid, now.year, now.month),
        WorklogService.instance.fetchMonthWorklogs(uid, now.year, now.month),
        ReminderService.instance.fetchMonthReminders(uid, now.year, now.month),
        HolidayService.instance.load(),
      ]).timeout(_cloudLoadTimeout);

      _profile = results[0] as EmployeeProfile;
      _settings = results[1] as WorkScheduleSettings;

      _attendance.clear();
      for (final r in results[2] as List<AttendanceRecord>) {
        _attendance[dateKey(r.date)] = r;
      }

      _worklogs.clear();
      for (final e in results[3] as List<WorklogEntry>) {
        final key = dateKey(e.date);
        _worklogs[key] = [...(_worklogs[key] ?? []), e];
      }

      _reminders.clear();
      for (final r in results[4] as List<ReminderEvent>) {
        final key = dateKey(r.startDateTime);
        _reminders[key] = [...(_reminders[key] ?? []), r];
      }

      // Cloud data loaded successfully — clear the session cache.
      await SessionCacheDb.instance.clear();
    } finally {
      _loading = false;
      notifyListeners();
      _refreshCalendarReminderSchedules();
      _refreshBackgroundReminders();
    }
  }

  /// Reload attendance + worklogs for an arbitrary month (calendar navigation).
  Future<void> loadMonth(int year, int month) async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;

    final results = await Future.wait([
      AttendanceService.instance.fetchMonthRecords(uid, year, month),
      WorklogService.instance.fetchMonthWorklogs(uid, year, month),
      ReminderService.instance.fetchMonthReminders(uid, year, month),
    ]);

    for (final r in results[0] as List<AttendanceRecord>) {
      _attendance[dateKey(r.date)] = r;
    }
    for (final e in results[1] as List<WorklogEntry>) {
      final key = dateKey(e.date);
      _worklogs[key] = [...(_worklogs[key] ?? []), e];
    }
    for (final r in results[2] as List<ReminderEvent>) {
      final key = dateKey(r.startDateTime);
      _reminders[key] = [...(_reminders[key] ?? []), r];
    }

    notifyListeners();
    _refreshCalendarReminderSchedules();
  }

  /// Clear all in-memory state (called on logout).
  void clear() {
    _profile = null;
    _settings = WorkScheduleSettings.defaults();
    _attendance.clear();
    _worklogs.clear();
    _reminders.clear();
    HolidayService.instance.clear();
    notifyListeners();
    NotificationService.instance.cancelBackgroundFallbackReminders();
  }

  void _refreshBackgroundReminders() {
    final enabled = _profile?.notificationsEnabled ?? true;
    NotificationService.instance.refreshBackgroundFallbackReminders(
      settings: _settings,
      enabled: enabled,
      holidays: HolidayService.instance.holidayKeys,
    );
  }

  /// Public entry point untuk re-jadwal pengingat dari luar (mis. dari
  /// RealtimeSyncService ketika kalender libur berubah).
  void refreshBackgroundReminders() => _refreshBackgroundReminders();

  void _refreshCalendarReminderSchedules() {
    final enabled = _profile?.notificationsEnabled ?? true;
    if (!enabled) return;
    for (final list in _reminders.values) {
      for (final reminder in list) {
        NotificationService.instance.scheduleReminder(reminder);
      }
    }
  }

  // ─── DERIVED DAY STATE ────────────────────────────────────────────────────

  DayDisplayState dayStateOf(DateTime day) {
    final todayNorm = _todayNorm();
    final dayNorm = DateTime(day.year, day.month, day.day);
    final isOffDay = _settings.offDays.contains(day.weekday);
    final record = attendanceOf(day);
    final isFuture = dayNorm.isAfter(todayNorm);

    if (record != null) {
      if (record.status == AttendanceStatus.present) {
        return isOffDay
            ? DayDisplayState.workedOnOffDay
            : DayDisplayState.presentWorkday;
      }
      return DayDisplayState.manualException;
    }

    if (isOffDay) return DayDisplayState.offDay;
    if (isFuture) return DayDisplayState.futureDay;

    final isToday = dayNorm == todayNorm;
    if (!isToday && _settings.autoMarkMissingAttendance) {
      return DayDisplayState.missingAttendance;
    }
    return DayDisplayState.futureDay;
  }

  DateTime _todayNorm() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  // ─── MONTH STATS ──────────────────────────────────────────────────────────

  ({int present, int missing, int offDay, int reminders}) monthStatsOf(
    DateTime month,
  ) {
    int present = 0, missing = 0, offDay = 0, reminders = 0;
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final today = _todayNorm();

    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(month.year, month.month, d);
      if (day.isAfter(today)) break;
      switch (dayStateOf(day)) {
        case DayDisplayState.presentWorkday:
        case DayDisplayState.workedOnOffDay:
          present++;
        case DayDisplayState.missingAttendance:
          missing++;
        case DayDisplayState.offDay:
          offDay++;
        default:
          break;
      }
    }

    for (final list in _reminders.values) {
      for (final r in list) {
        if (r.startDateTime.year == month.year &&
            r.startDateTime.month == month.month) {
          reminders++;
        }
      }
    }

    return (
      present: present,
      missing: missing,
      offDay: offDay,
      reminders: reminders,
    );
  }

  // ─── WEEK ATTENDANCE ──────────────────────────────────────────────────────

  List<({DateTime date, DayDisplayState state})> weekStatesOf(DateTime day) {
    final monday = day.subtract(Duration(days: day.weekday - 1));
    return List.generate(7, (i) {
      final d = monday.add(Duration(days: i));
      return (date: d, state: dayStateOf(d));
    });
  }
}
