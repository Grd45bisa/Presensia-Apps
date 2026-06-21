import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../models/app_models.dart';

/// Channel untuk notifikasi sistem bar.
/// Public agar NotificationProvider bisa memilih channel yang sesuai.
enum NotifChannel {
  reminders(
    'reminders',
    'Pengingat',
    'Notifikasi pengingat acara kalender',
    Importance.high,
    Priority.high,
  ),
  attendance(
    'attendance',
    'Absensi',
    'Pengingat check-in dan check-out harian',
    Importance.high,
    Priority.high,
  ),
  tracker(
    'tracker',
    'Tracker',
    'Pengingat pencatatan aktivitas harian',
    Importance.defaultImportance,
    Priority.defaultPriority,
  ),
  system(
    'system',
    'Sistem',
    'Notifikasi umum aplikasi',
    Importance.defaultImportance,
    Priority.defaultPriority,
  );

  const NotifChannel(
      this.channelId, this.channelName, this.channelDesc,
      this.importance, this.priority);

  final String channelId;
  final String channelName;
  final String channelDesc;
  final Importance importance;
  final Priority priority;
}

/// Set of dates (YYYY-MM-DD, server/local) the app should treat as holidays so
/// that scheduled attendance reminders are skipped automatically.
typedef HolidaySet = Set<String>;

/// Snapshot of what is currently scheduled, persisted to SharedPreferences so
/// the native BootReceiver can re-arm alarms after a device reboot even though
/// the Flutter engine is not running yet.
@immutable
class ReminderScheduleSnapshot {
  final bool enabled;
  final String? checkInTime; // HH:MM
  final String? checkOutTime; // HH:MM
  final String? trackerTime; // HH:MM
  final List<int> offDays;

  const ReminderScheduleSnapshot({
    required this.enabled,
    required this.checkInTime,
    required this.checkOutTime,
    required this.trackerTime,
    required this.offDays,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'check_in_time': checkInTime,
    'check_out_time': checkOutTime,
    'tracker_time': trackerTime,
    'off_days': offDays,
  };

  factory ReminderScheduleSnapshot.fromJson(Map<String, dynamic> json) =>
      ReminderScheduleSnapshot(
        enabled: json['enabled'] as bool? ?? false,
        checkInTime: json['check_in_time'] as String?,
        checkOutTime: json['check_out_time'] as String?,
        trackerTime: json['tracker_time'] as String?,
        offDays:
            (json['off_days'] as List<dynamic>?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [6, 7],
      );

  static const ReminderScheduleSnapshot empty = ReminderScheduleSnapshot(
    enabled: false,
    checkInTime: null,
    checkOutTime: null,
    trackerTime: null,
    offDays: [6, 7],
  );
}

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const String _notificationIcon = 'ic_stat_presensia';
  static const DrawableResourceAndroidBitmap largeIcon =
      DrawableResourceAndroidBitmap('presensia_notification_large');

  // Stable notification IDs per reminder kind, offset by a per-day delta so
  // we can schedule several days ahead without colliding with each other.
  static const int _backgroundScheduleDays = 7;
  static const int _checkInReminderBaseId = 1000000;
  static const int _trackerReminderBaseId = 2000000;
  static const int _checkOutReminderBaseId = 3000000;

  // Method channel used to talk to the native Android side: re-arming alarms
  // on boot + requesting battery-optimization whitelist.
  static const MethodChannel _nativeChannel = MethodChannel(
    'id.presensia.face_recognizer/notifications',
  );

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  Future<void>? _initFuture;

  Future<void> init() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    tz_data.initializeTimeZones();
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
      debugPrint('[NotifService] timezone set to: ${tzInfo.identifier}');
    } catch (e) {
      debugPrint('[NotifService] timezone detection failed: $e, falling back to UTC');
      try {
        tz.setLocalLocation(tz.getLocation('UTC'));
      } catch (_) {}
    }

    const android = AndroidInitializationSettings(_notificationIcon);
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    _initialized = true;

    // Request permissions synchronously so they are granted before any
    // scheduling attempt. Do NOT cancelAll() here — that was wiping
    // legitimately scheduled reminders.
    try {
      await _requestPermissions().timeout(const Duration(seconds: 5));
    } catch (_) {}
    debugPrint('[NotifService] init complete, tz.local=${tz.local.name}');
  }

  Future<void> _requestPermissions() async {
    // Android 13+ (API 33) memerlukan izin eksplisit POST_NOTIFICATIONS
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
    await androidImpl?.requestExactAlarmsPermission();

    // iOS
    final iosImpl = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    await iosImpl?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  // ── Show immediate system-bar notification ────────────────────────────────

  /// Tampilkan notifikasi langsung di notification bar HP.
  /// Dipakai oleh NotificationProvider setiap kali ada item baru yang
  /// belum pernah ditampilkan ke OS.
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
    NotifChannel channel = NotifChannel.system,
  }) async {
    if (!_initialized) await init();

    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.channelId,
          channel.channelName,
          channelDescription: channel.channelDesc,
          importance: channel.importance,
          priority: channel.priority,
          icon: _notificationIcon,
          largeIcon: largeIcon,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  // ── Scheduled reminders (calendar events) ─────────────────────────────────

  int _reminderNotificationId(String eventId, int offset) {
    return (eventId.hashCode ^ offset).toSigned(31);
  }

  Future<void> scheduleReminder(ReminderEvent event) async {
    if (!_initialized) await init();
    await cancelReminder(event);

    final offsets = _effectiveReminderOffsets(event);
    debugPrint('[NotifService] scheduleReminder "${event.title}" '
        'at=${event.startDateTime}, offsets=$offsets');

    for (final offset in offsets) {
      final notifTime =
          event.startDateTime.subtract(Duration(minutes: offset));
      if (notifTime.isBefore(DateTime.now())) {
        debugPrint('[NotifService]   skip offset=$offset (in the past: $notifTime)');
        continue;
      }

      final id = _reminderNotificationId(event.id, offset);
      final title = _buildReminderTitle(event, offset);
      final body = _buildReminderBody(event, offset);
      final scheduledTz = tz.TZDateTime.from(notifTime, tz.local);

      debugPrint('[NotifService]   scheduling id=$id offset=${offset}m '
          'at=$scheduledTz (tz=${tz.local.name})');

      final ch = NotifChannel.reminders;
      try {
        await _zonedSchedule(
          id,
          title,
          body,
          scheduledTz,
          NotificationDetails(
            android: AndroidNotificationDetails(
              ch.channelId,
              ch.channelName,
              channelDescription: ch.channelDesc,
              importance: ch.importance,
              priority: ch.priority,
              icon: _notificationIcon,
              largeIcon: largeIcon,
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
        );
        debugPrint('[NotifService]   ✓ scheduled OK id=$id');
      } catch (e) {
        debugPrint('[NotifService]   ✗ scheduling FAILED id=$id: $e');
      }
    }
  }

  Future<void> cancelReminder(ReminderEvent event) async {
    if (!_initialized) await init();
    for (final offset in _effectiveReminderOffsets(event)) {
      await _plugin.cancel(_reminderNotificationId(event.id, offset));
    }
  }

  List<int> _effectiveReminderOffsets(ReminderEvent event) {
    final offsets = <int>{...event.reminderOffsetsInMinutes, 0}.toList();
    offsets.sort((a, b) => b.compareTo(a));
    return offsets;
  }

  String _buildReminderTitle(ReminderEvent event, int offset) {
    if (offset == 0) {
      return 'Waktu untuk ${event.title}';
    }
    return 'Pengingat ${event.title}';
  }

  String _buildReminderBody(ReminderEvent event, int offset) {
    final whenLabel = event.isAllDay
        ? 'hari ini'
        : 'pukul ${_formatTime(event.startDateTime)}';
    if (offset == 0) {
      return 'Waktu untuk ${event.title} sudah tiba sekitar $whenLabel.';
    }
    return 'Waktu untuk ${event.title} sekitar ${_formatOffset(offset)} lagi, $whenLabel.';
  }

  String _formatOffset(int minutes) {
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return hours == 1 ? '1 jam' : '$hours jam';
    }
    if (minutes > 60) {
      final hours = minutes ~/ 60;
      final remMinutes = minutes % 60;
      return '$hours jam $remMinutes menit';
    }
    return '$minutes menit';
  }

  String _formatTime(DateTime value) {
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  // ── Background scheduled reminders ────────────────────────────────────────
  //
  // These are scheduled via AlarmManager (zonedSchedule) so they fire even
  // when the Flutter process has been killed. The reminder times are read
  // from WorkScheduleSettings, so each user can customise their own.
  //
  // Attendance reminders are *state based*: we cannot inspect AppStore from a
  // killed process at fire time. Instead we always schedule them, and cancel
  // the ones that become irrelevant the next time the app opens (see
  // [cancelAttendanceRemindersFor]).

  /// Schedules the daily reminder windows for the next
  /// [_backgroundScheduleDays] days based on the user's settings.
  ///
  /// [holidays] is the set of holiday date keys (YYYY-MM-DD) for which
  /// attendance reminders should be skipped. Optional — pass null to skip
  /// the holiday filter.
  Future<void> refreshBackgroundFallbackReminders({
    required WorkScheduleSettings settings,
    required bool enabled,
    HolidaySet? holidays,
  }) async {
    if (!_initialized) await init();
    await cancelBackgroundFallbackReminders();

    final effectiveEnabled = enabled && settings.reminderEnabled;
    // Always persist the snapshot so BootReceiver knows what to re-arm (or
    // that it should stay silent when disabled).
    await _persistSnapshot(
      ReminderScheduleSnapshot(
        enabled: effectiveEnabled,
        checkInTime: settings.checkInReminderTime.toIsoString(),
        checkOutTime: settings.checkOutReminderTime.toIsoString(),
        trackerTime: settings.trackerReminderTime.toIsoString(),
        offDays: settings.offDays.toList(),
      ),
    );

    if (!effectiveEnabled) return;

    final holidayKeys = holidays ?? const <String>{};
    final now = DateTime.now();

    for (int i = 0; i < _backgroundScheduleDays; i++) {
      final day = DateTime(now.year, now.month, now.day)
          .add(Duration(days: i));

      // Skip configured weekly off-days.
      if (settings.offDays.contains(day.weekday)) continue;
      // Skip national/official holidays.
      if (holidayKeys.contains(_dateKey(day))) continue;

      await _scheduleFallback(
        id: _idForDay(_checkInReminderBaseId, day),
        when: _atTime(day, settings.checkInReminderTime),
        title: 'Jangan lupa check-in',
        body: 'Mulai hari kerja dengan presensi wajah.',
        channel: NotifChannel.attendance,
      );
      await _scheduleFallback(
        id: _idForDay(_trackerReminderBaseId, day),
        when: _atTime(day, settings.trackerReminderTime),
        title: 'Tracker aktivitas belum diisi?',
        body: 'Catat progres kerja hari ini supaya laporan tetap rapi.',
        channel: NotifChannel.tracker,
      );
      await _scheduleFallback(
        id: _idForDay(_checkOutReminderBaseId, day),
        when: _atTime(day, settings.checkOutReminderTime),
        title: 'Jangan lupa check-out',
        body: 'Selesaikan presensi saat pekerjaan hari ini sudah berakhir.',
        channel: NotifChannel.attendance,
      );
    }
  }

  Future<void> cancelBackgroundFallbackReminders() async {
    if (!_initialized) await init();
    final today = DateTime.now();
    for (int i = -1; i < _backgroundScheduleDays + 1; i++) {
      final day = DateTime(today.year, today.month, today.day)
          .add(Duration(days: i));
      await _plugin.cancel(_idForDay(_checkInReminderBaseId, day));
      await _plugin.cancel(_idForDay(_trackerReminderBaseId, day));
      await _plugin.cancel(_idForDay(_checkOutReminderBaseId, day));
    }
  }

  /// Cancel the scheduled attendance reminder(s) for a given [day] so that a
  /// user who already checked in / checked out does not get a stale "don't
  /// forget" notification. Call this whenever attendance state changes.
  Future<void> cancelAttendanceRemindersFor(DateTime day) async {
    if (!_initialized) return;
    await _plugin.cancel(_idForDay(_checkInReminderBaseId, day));
    await _plugin.cancel(_idForDay(_checkOutReminderBaseId, day));
  }

  /// Cancel the scheduled tracker reminder for [day] once at least one
  /// worklog entry has been recorded.
  Future<void> cancelTrackerReminderFor(DateTime day) async {
    if (!_initialized) return;
    await _plugin.cancel(_idForDay(_trackerReminderBaseId, day));
  }

  Future<void> _scheduleFallback({
    required int id,
    required DateTime when,
    required String title,
    required String body,
    required NotifChannel channel,
  }) async {
    if (!when.isAfter(DateTime.now())) return;
    await _zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(when, tz.local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel.channelId,
          channel.channelName,
          channelDescription: channel.channelDesc,
          importance: channel.importance,
          priority: channel.priority,
          icon: _notificationIcon,
          largeIcon: largeIcon,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  Future<void> _zonedSchedule(
    int id,
    String title,
    String body,
    tz.TZDateTime scheduledDate,
    NotificationDetails notificationDetails,
  ) async {
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledDate,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('[NotifService] exact alarm failed ($e), trying inexact...');
      try {
        await _plugin.zonedSchedule(
          id,
          title,
          body,
          scheduledDate,
          notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (e2) {
        debugPrint('[NotifService] inexact alarm also failed: $e2');
        rethrow;
      }
    }
  }

  int _idForDay(int baseId, DateTime day) {
    final utcDay = DateTime.utc(day.year, day.month, day.day);
    return baseId + utcDay.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  }

  DateTime _atTime(DateTime day, TimeOfDaySetting t) =>
      DateTime(day.year, day.month, day.day, t.hour, t.minute);

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Native bridges: boot re-arm + battery whitelist ───────────────────────

  /// Ask the native side to re-arm the scheduled alarms using the last
  /// persisted snapshot. Called on app launch as a safety net even when the
  /// device has not rebooted.
  Future<void> rearmFromSnapshot() async {
    if (kIsWeb) return;
    try {
      await _nativeChannel.invokeMethod('rearmReminders');
    } on MissingPluginException {
      // Native side not wired up (e.g. older build) — safe to ignore.
    } catch (_) {}
  }

  /// Returns true if the app is already exempt from battery optimizations
  /// (so reminders survive aggressive OEM kill heuristics).
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb) return true;
    try {
      final result =
          await _nativeChannel.invokeMethod<bool>('isIgnoringBatteryOpt');
      return result ?? false;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system dialog asking the user to whitelist the app from
  /// battery optimizations. Should be called once after notifications are
  /// enabled by the user.
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb) return;
    try {
      await _nativeChannel.invokeMethod('requestIgnoreBatteryOpt');
    } on MissingPluginException {
      // Native side not wired up — ignore.
    } catch (_) {}
  }

  Future<void> _persistSnapshot(ReminderScheduleSnapshot snapshot) async {
    try {
      // Push the structured values to the native side so the BootReceiver can
      // re-arm alarms synchronously from native prefs after a reboot (the
      // Flutter engine is not running yet at that point).
      if (!kIsWeb) {
        await _nativeChannel.invokeMethod('saveSnapshot', {
          'enabled': snapshot.enabled,
          'check_in_time': snapshot.checkInTime,
          'check_out_time': snapshot.checkOutTime,
          'tracker_time': snapshot.trackerTime,
          'off_days': snapshot.offDays,
        });
      }
    } catch (_) {}
  }
}
