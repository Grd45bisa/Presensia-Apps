import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/app_notification.dart';
import '../services/auth_service.dart';
import '../services/notification_read_service.dart';
import '../services/notification_service.dart';
import '../store/app_store.dart';
import '../theme/app_colors.dart';

/// Derives in-app notification items from live AppStore state.
///
/// Read notifications are persisted in Supabase so the same account keeps its
/// read state after app restart or reinstall.
class NotificationProvider extends ChangeNotifier {
  static final NotificationProvider instance = NotificationProvider._();
  NotificationProvider._();

  bool _disposed = false;

  final Map<String, bool> _readState = {};
  String? _readStateUserId;
  Future<void>? _readStateLoad;

  // Set notifikasi yang sudah pernah di-push ke OS (supaya tidak double).
  final Set<String> _pushedToOs = {};

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

  Future<void> ensureReadStateLoaded() {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return Future.value();

    if (_readStateUserId == uid && _readStateLoad != null) {
      return _readStateLoad!;
    }

    _readStateUserId = uid;
    _readStateLoad = NotificationReadService.instance
        .fetchReadIds(uid)
        .then((ids) {
          _readState
            ..clear()
            ..addEntries(ids.map((id) => MapEntry(id, true)));
          notifyListeners();
        })
        .catchError((_) {});

    return _readStateLoad!;
  }

  List<AppNotification> compute() {
    final store = AppStore.instance;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = AppStore.dateKey(today);
    final items = <AppNotification>[];

    final reminders = store.remindersOf(today);
    for (final r in reminders) {
      final timeStr = r.isAllDay ? 'Seharian' : _fmtTime(r.startDateTime);
      final isPast = !r.isAllDay && r.startDateTime.isBefore(now);
      final id = 'cal_${r.id}';
      items.add(
        AppNotification(
          id: id,
          category: NotificationCategory.calendar,
          priority: NotificationPriority.high,
          title: r.title,
          subtitle: isPast ? 'Sudah lewat - $timeStr' : 'Pukul $timeStr',
          timeLabel: timeStr,
          createdAt: r.startDateTime,
          icon: Icons.event_rounded,
          iconColor: AppColors.primary,
          iconBg: AppColors.primaryLight,
          isRead: _readState[id] ?? false,
        ),
      );
    }

    final record = store.attendanceOf(today);
    final isOffDay = store.settings.offDays.contains(today.weekday);

    if (!isOffDay) {
      if (record == null) {
        final id = 'att_checkin_$todayKey';
        items.add(
          AppNotification(
            id: id,
            category: NotificationCategory.attendance,
            priority: NotificationPriority.high,
            title: 'Kamu belum check-in hari ini',
            subtitle: 'Lakukan presensi untuk mencatat kehadiran',
            timeLabel: 'Hari ini',
            createdAt: today,
            icon: Icons.login_rounded,
            iconColor: AppColors.missing,
            iconBg: AppColors.missingLight,
            isRead: _readState[id] ?? false,
          ),
        );
      } else if (record.checkIn != null && record.checkOut == null) {
        final checkInStr = _fmtTod(record.checkIn!);
        final id = 'att_checkout_$todayKey';
        items.add(
          AppNotification(
            id: id,
            category: NotificationCategory.attendance,
            priority: NotificationPriority.high,
            title: 'Jangan lupa check-out sebelum pulang',
            subtitle: 'Check-in tercatat pukul $checkInStr',
            timeLabel: 'Hari ini',
            createdAt: DateTime(
              today.year,
              today.month,
              today.day,
              record.checkIn!.hour,
              record.checkIn!.minute,
            ),
            icon: Icons.logout_rounded,
            iconColor: AppColors.warning,
            iconBg: AppColors.warningLight,
            isRead: _readState[id] ?? false,
          ),
        );
      } else if (record.checkIn != null && record.checkOut != null) {
        final id = 'att_done_$todayKey';
        items.add(
          AppNotification(
            id: id,
            category: NotificationCategory.attendance,
            priority: NotificationPriority.low,
            title: 'Absensi hari ini sudah selesai',
            subtitle:
                '${_fmtTod(record.checkIn!)} - ${_fmtTod(record.checkOut!)}',
            timeLabel: _fmtTod(record.checkOut!),
            createdAt: DateTime(
              today.year,
              today.month,
              today.day,
              record.checkOut!.hour,
              record.checkOut!.minute,
            ),
            icon: Icons.task_alt_rounded,
            iconColor: AppColors.success,
            iconBg: AppColors.successLight,
            isRead: _readState[id] ?? false,
          ),
        );
      }
    }

    final worklogs = store.worklogsOf(today);
    if (worklogs.isEmpty && !isOffDay) {
      final id = 'trk_empty_$todayKey';
      items.add(
        AppNotification(
          id: id,
          category: NotificationCategory.tracker,
          priority: NotificationPriority.medium,
          title: 'Tracker hari ini belum mencatat aktivitas',
          subtitle: 'Mulai timer atau tambah entry manual',
          timeLabel: 'Hari ini',
          createdAt: today,
          icon: Icons.timer_outlined,
          iconColor: AppColors.textSecondary,
          iconBg: AppColors.background,
          isRead: _readState[id] ?? false,
        ),
      );
    }

    final tomorrow = today.add(const Duration(days: 1));
    final tomorrowIsOff = store.settings.offDays.contains(tomorrow.weekday);
    if (tomorrowIsOff) {
      const dayNames = [
        '',
        'Senin',
        'Selasa',
        'Rabu',
        'Kamis',
        'Jumat',
        'Sabtu',
        'Minggu',
      ];
      final id = 'sched_tomorrow_off_${AppStore.dateKey(tomorrow)}';
      items.add(
        AppNotification(
          id: id,
          category: NotificationCategory.schedule,
          priority: NotificationPriority.medium,
          title: 'Besok adalah jadwal libur (${dayNames[tomorrow.weekday]})',
          subtitle: null,
          timeLabel: 'Besok',
          createdAt: today,
          icon: Icons.weekend_rounded,
          iconColor: AppColors.error,
          iconBg: AppColors.errorLight,
          isRead: _readState[id] ?? false,
        ),
      );
    }

    items.sort((a, b) {
      if (a.isRead != b.isRead) return a.isRead ? 1 : -1;

      final timeCompare = b.createdAt.compareTo(a.createdAt);
      if (timeCompare != 0) return timeCompare;

      return a.priority.index.compareTo(b.priority.index);
    });
    return items;
  }

  int get unreadCount => compute().where((n) => !n.isRead).length;

  void markRead(String id) {
    _readState[id] = true;
    _persistRead(id);
    notifyListeners();
  }

  void markAllRead() {
    final items = compute();
    for (final n in items) {
      _readState[n.id] = true;
    }
    _persistAllRead(items.map((n) => n.id));
    notifyListeners();
  }

  /// Refresh state dan push notifikasi baru ke system bar HP.
  /// Dipanggil oleh RealtimeSyncService saat data berubah.
  void refresh() {
    unawaited(ensureReadStateLoaded().then((_) => _pushNewToOs()));
    notifyListeners();
  }

  void resetReadState() {
    _readState.clear();
    _readStateUserId = null;
    _readStateLoad = null;
    _pushedToOs.clear();
    notifyListeners();
  }

  Future<void> _pushNewToOs() async {
    final items = compute().where((n) => !n.isRead);
    for (final n in items) {
      if (_pushedToOs.contains(n.id)) continue;
      if (n.priority == NotificationPriority.low) continue;
      if (n.category == NotificationCategory.calendar) continue;

      final channel = switch (n.category) {
        NotificationCategory.attendance => NotifChannel.attendance,
        NotificationCategory.tracker => NotifChannel.tracker,
        NotificationCategory.calendar => NotifChannel.reminders,
        _ => NotifChannel.system,
      };

      try {
        await NotificationService.instance.showNow(
          id: n.id.hashCode & 0x7FFFFFFF,
          title: n.title,
          body: n.subtitle ?? n.timeLabel,
          channel: channel,
        );
        _pushedToOs.add(n.id);
      } catch (_) {}
    }
  }

  void _persistRead(String id) {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    unawaited(
      NotificationReadService.instance.markRead(uid, id).catchError((_) {}),
    );
  }

  void _persistAllRead(Iterable<String> ids) {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    unawaited(
      NotificationReadService.instance.markAllRead(uid, ids).catchError((_) {}),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
