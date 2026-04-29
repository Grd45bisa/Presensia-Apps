import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../models/app_notification.dart';
import '../store/app_store.dart';
import '../theme/app_colors.dart';

/// Derives in-app notification items from live AppStore state.
/// No external data source — everything is computed from what's already loaded.
class NotificationProvider extends ChangeNotifier {
  static final NotificationProvider instance = NotificationProvider._();
  NotificationProvider._();

  @override
  void notifyListeners() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.transientCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        super.notifyListeners();
      });
    } else {
      super.notifyListeners();
    }
  }

  final Map<String, bool> _readState = {};

  List<AppNotification> compute() {
    final store = AppStore.instance;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final items = <AppNotification>[];

    // ── 1. PENGINGAT KALENDER (high) ──────────────────────────────────────────
    final reminders = store.remindersOf(today);
    for (final r in reminders) {
      final timeStr = r.isAllDay
          ? 'Seharian'
          : _fmtTime(r.startDateTime);
      final isPast = !r.isAllDay && r.startDateTime.isBefore(now);
      items.add(AppNotification(
        id: 'cal_${r.id}',
        category: NotificationCategory.calendar,
        priority: NotificationPriority.high,
        title: r.title,
        subtitle: isPast ? 'Sudah lewat · $timeStr' : 'Pukul $timeStr',
        timeLabel: timeStr,
        icon: Icons.event_rounded,
        iconColor: AppColors.primary,
        iconBg: AppColors.primaryLight,
        isRead: _readState['cal_${r.id}'] ?? false,
      ));
    }

    // ── 2. STATUS ABSENSI (high) ───────────────────────────────────────────────
    final record = store.attendanceOf(today);
    final isOffDay = store.settings.offDays.contains(today.weekday);

    if (!isOffDay) {
      if (record == null) {
        items.add(AppNotification(
          id: 'att_checkin',
          category: NotificationCategory.attendance,
          priority: NotificationPriority.high,
          title: 'Kamu belum check-in hari ini',
          subtitle: 'Lakukan presensi untuk mencatat kehadiran',
          timeLabel: 'Hari ini',
          icon: Icons.login_rounded,
          iconColor: AppColors.missing,
          iconBg: AppColors.missingLight,
          isRead: _readState['att_checkin'] ?? false,
        ));
      } else if (record.checkIn != null && record.checkOut == null) {
        final checkInStr = _fmtTod(record.checkIn!);
        items.add(AppNotification(
          id: 'att_checkout',
          category: NotificationCategory.attendance,
          priority: NotificationPriority.high,
          title: 'Jangan lupa check-out sebelum pulang',
          subtitle: 'Check-in tercatat pukul $checkInStr',
          timeLabel: 'Hari ini',
          icon: Icons.logout_rounded,
          iconColor: AppColors.warning,
          iconBg: AppColors.warningLight,
          isRead: _readState['att_checkout'] ?? false,
        ));
      } else if (record.checkIn != null && record.checkOut != null) {
        items.add(AppNotification(
          id: 'att_done',
          category: NotificationCategory.attendance,
          priority: NotificationPriority.low,
          title: 'Absensi hari ini sudah selesai',
          subtitle: '${_fmtTod(record.checkIn!)} – ${_fmtTod(record.checkOut!)}',
          timeLabel: _fmtTod(record.checkOut!),
          icon: Icons.task_alt_rounded,
          iconColor: AppColors.success,
          iconBg: AppColors.successLight,
          isRead: _readState['att_done'] ?? false,
        ));
      }
    }

    // ── 3. STATUS TRACKER (medium) ────────────────────────────────────────────
    final worklogs = store.worklogsOf(today);

    if (worklogs.isEmpty && !isOffDay) {
      items.add(AppNotification(
        id: 'trk_empty',
        category: NotificationCategory.tracker,
        priority: NotificationPriority.medium,
        title: 'Tracker hari ini belum mencatat aktivitas',
        subtitle: 'Mulai timer atau tambah entry manual',
        timeLabel: 'Hari ini',
        icon: Icons.timer_outlined,
        iconColor: AppColors.textSecondary,
        iconBg: AppColors.background,
        isRead: _readState['trk_empty'] ?? false,
      ));
    }

    // ── 4. INFO JADWAL KERJA (medium) ─────────────────────────────────────────
    final tomorrow = today.add(const Duration(days: 1));
    final tomorrowIsOff = store.settings.offDays.contains(tomorrow.weekday);
    if (tomorrowIsOff) {
      const dayNames = ['', 'Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
      items.add(AppNotification(
        id: 'sched_tomorrow_off',
        category: NotificationCategory.schedule,
        priority: NotificationPriority.medium,
        title: 'Besok adalah jadwal libur (${dayNames[tomorrow.weekday]})',
        subtitle: null,
        timeLabel: 'Besok',
        icon: Icons.weekend_rounded,
        iconColor: AppColors.error,
        iconBg: AppColors.errorLight,
        isRead: _readState['sched_tomorrow_off'] ?? false,
      ));
    }

    // Sort: high first, then medium, then low; within same priority keep insertion order
    items.sort((a, b) => a.priority.index.compareTo(b.priority.index));
    return items;
  }

  int get unreadCount {
    final all = compute();
    return all.where((n) => !n.isRead).length;
  }

  void markRead(String id) {
    _readState[id] = true;
    notifyListeners();
  }

  void markAllRead() {
    for (final n in compute()) {
      _readState[n.id] = true;
    }
    notifyListeners();
  }

  void refresh() => notifyListeners();

  // Reset read state daily (ids are date-scoped so they naturally expire next day)
  void resetReadState() {
    _readState.clear();
    notifyListeners();
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
