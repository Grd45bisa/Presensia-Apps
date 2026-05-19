import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  static const String _notificationIcon = '@mipmap/launcher_icon';
  static const largeIcon =
      DrawableResourceAndroidBitmap('notification_large_logo');
  static const int _backgroundScheduleDays = 7;
  static const int _checkInReminderBaseId = 1000000;
  static const int _trackerReminderBaseId = 2000000;
  static const int _checkOutReminderBaseId = 3000000;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();

    const android = AndroidInitializationSettings(_notificationIcon);
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    await _requestPermissions();
    _initialized = true;
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

  // ── Scheduled reminders ───────────────────────────────────────────────────

  Future<void> scheduleReminder(ReminderEvent event) async {
    if (!_initialized) return;
    await cancelReminder(event);

    for (final offset in _effectiveReminderOffsets(event)) {
      final notifTime =
          event.startDateTime.subtract(Duration(minutes: offset));
      if (notifTime.isBefore(DateTime.now())) continue;

      final id = event.id.hashCode ^ offset;
      final body = offset == 0 ? 'Sedang berlangsung' : '$offset menit lagi';

      final ch = NotifChannel.reminders;
      await _zonedSchedule(
        id,
        event.title,
        body,
        tz.TZDateTime.from(notifTime, tz.local),
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
    }
  }

  Future<void> cancelReminder(ReminderEvent event) async {
    if (!_initialized) return;
    for (final offset in _effectiveReminderOffsets(event)) {
      await _plugin.cancel(event.id.hashCode ^ offset);
    }
  }

  List<int> _effectiveReminderOffsets(ReminderEvent event) {
    final offsets = <int>{...event.reminderOffsetsInMinutes, 0}.toList();
    offsets.sort((a, b) => b.compareTo(a));
    return offsets;
  }

  // ── Background fallback reminders ────────────────────────────────────────

  /// Schedules daily local fallback notifications so core reminders still
  /// appear after Android stops the Flutter process. These are intentionally
  /// generic; server-driven realtime notifications require push/FCM.
  Future<void> refreshBackgroundFallbackReminders({
    required WorkScheduleSettings settings,
    required bool enabled,
  }) async {
    if (!_initialized) await init();
    await cancelBackgroundFallbackReminders();
    if (!enabled) return;

    final now = DateTime.now();
    for (int i = 0; i < _backgroundScheduleDays; i++) {
      final day = DateTime(now.year, now.month, now.day).add(
        Duration(days: i),
      );
      if (settings.offDays.contains(day.weekday)) continue;

      await _scheduleFallback(
        id: _idForDay(_checkInReminderBaseId, day),
        when: DateTime(day.year, day.month, day.day, 8, 15),
        title: 'Jangan lupa check-in',
        body: 'Mulai hari kerja dengan presensi wajah.',
        channel: NotifChannel.attendance,
      );
      await _scheduleFallback(
        id: _idForDay(_trackerReminderBaseId, day),
        when: DateTime(day.year, day.month, day.day, 13, 0),
        title: 'Tracker aktivitas belum diisi?',
        body: 'Catat progres kerja hari ini supaya laporan tetap rapi.',
        channel: NotifChannel.tracker,
      );
      await _scheduleFallback(
        id: _idForDay(_checkOutReminderBaseId, day),
        when: DateTime(day.year, day.month, day.day, 17, 0),
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
      final day = DateTime(today.year, today.month, today.day).add(
        Duration(days: i),
      );
      await _plugin.cancel(_idForDay(_checkInReminderBaseId, day));
      await _plugin.cancel(_idForDay(_trackerReminderBaseId, day));
      await _plugin.cancel(_idForDay(_checkOutReminderBaseId, day));
    }
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
    } catch (_) {
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
    }
  }

  int _idForDay(int baseId, DateTime day) {
    final utcDay = DateTime.utc(day.year, day.month, day.day);
    return baseId + utcDay.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  }
}
