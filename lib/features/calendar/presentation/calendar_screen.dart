import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/app_models.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/services/attendance_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/notification_service.dart';
import '../../../shared/services/reminder_service.dart';
import '../../../shared/services/worklog_service.dart';
import '../../../shared/services/project_service.dart';
import '../../../shared/providers/notification_provider.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with SingleTickerProviderStateMixin {
  static const _uuid = Uuid();
  static const double _fabBottomOffset = 0;
  static const double _contentBottomGap = 184;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
  CalendarFormat _calendarFormat = CalendarFormat.month;

  final _store = AppStore.instance;
  final Map<String, _CalendarDayMeta> _dayMetaCache = {};
  final Set<String> _loadedMonthKeys = {};

  // ─── FAB STATE ────────────────────────────────────────────────────────────
  bool _fabExpanded = false;
  late AnimationController _fabCtrl;
  late Animation<double> _fabRotate;
  late Animation<double> _fabScale;

  @override
  void initState() {
    super.initState();
    _fabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fabRotate = Tween<double>(
      begin: 0,
      end: 0.375,
    ).animate(CurvedAnimation(parent: _fabCtrl, curve: Curves.easeInOut));
    _fabScale = CurvedAnimation(parent: _fabCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _fabCtrl.dispose();
    super.dispose();
  }

  void _toggleFab() {
    setState(() => _fabExpanded = !_fabExpanded);
    if (_fabExpanded) {
      _fabCtrl.forward();
    } else {
      _fabCtrl.reverse();
    }
  }

  void _closeFab() {
    if (_fabExpanded) {
      setState(() => _fabExpanded = false);
      _fabCtrl.reverse();
    }
  }

  Future<void> _refreshCalendar() async {
    _closeFab();
    await _loadMonthIfNeeded(_focusedDay, force: true);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Kalender berhasil diperbarui'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _loadMonthIfNeeded(DateTime month, {bool force = false}) async {
    final key = '${month.year}-${month.month.toString().padLeft(2, '0')}';
    if (!force && _loadedMonthKeys.contains(key)) return;
    _loadedMonthKeys.add(key);
    await _store.loadMonth(month.year, month.month);
  }

  // ─── STATUS STYLES ────────────────────────────────────────────────────────

  _StatusStyle _attendanceStyle(AttendanceStatus s) {
    switch (s) {
      case AttendanceStatus.present:
        return const _StatusStyle(
          label: 'Hadir',
          icon: Icons.check_rounded,
          color: AppColors.success,
          bg: AppColors.successLight,
        );
      case AttendanceStatus.leave:
        return const _StatusStyle(
          label: 'Cuti',
          icon: Icons.beach_access_rounded,
          color: Color(0xFF3B82F6),
          bg: Color(0xFFEFF6FF),
        );
      case AttendanceStatus.sick:
        return const _StatusStyle(
          label: 'Sakit',
          icon: Icons.healing_rounded,
          color: Color(0xFFDB2777),
          bg: Color(0xFFFDF2F8),
        );
      case AttendanceStatus.training:
        return const _StatusStyle(
          label: 'Training',
          icon: Icons.school_rounded,
          color: Color(0xFF0D9488),
          bg: Color(0xFFF0FDFA),
        );
      case AttendanceStatus.meeting:
        return const _StatusStyle(
          label: 'Meeting',
          icon: Icons.groups_rounded,
          color: Color(0xFF7C3AED),
          bg: Color(0xFFF5F3FF),
        );
      case AttendanceStatus.holiday:
        return const _StatusStyle(
          label: 'Libur',
          icon: Icons.celebration_rounded,
          color: Color(0xFFF97316),
          bg: Color(0xFFFFF7ED),
        );
      case AttendanceStatus.otherException:
        return const _StatusStyle(
          label: 'Lainnya',
          icon: Icons.info_outline_rounded,
          color: Color(0xFF6366F1),
          bg: Color(0xFFEEF2FF),
        );
    }
  }

  _DayCellStyle _dayCellStyle(DayDisplayState state, AttendanceStatus? status) {
    switch (state) {
      case DayDisplayState.presentWorkday:
        return const _DayCellStyle(
          bg: AppColors.successLight,
          border: AppColors.success,
          text: AppColors.success,
          icon: Icons.check_rounded,
        );
      case DayDisplayState.workedOnOffDay:
        return const _DayCellStyle(
          bg: AppColors.successLight,
          border: AppColors.success,
          text: AppColors.success,
          icon: Icons.check_rounded,
          extraLabel: 'Libur',
        );
      case DayDisplayState.offDay:
        return const _DayCellStyle(
          bg: AppColors.errorLight,
          border: AppColors.error,
          text: AppColors.error,
          icon: Icons.weekend_rounded,
        );
      case DayDisplayState.missingAttendance:
        return const _DayCellStyle(
          bg: AppColors.missingLight,
          border: AppColors.missing,
          text: AppColors.missing,
          icon: Icons.warning_amber_rounded,
        );
      case DayDisplayState.manualException:
        if (status != null) {
          final s = _attendanceStyle(status);
          return _DayCellStyle(
            bg: s.bg,
            border: s.color,
            text: s.color,
            icon: s.icon,
          );
        }
        return const _DayCellStyle(
          bg: Color(0xFFEFF6FF),
          border: Color(0xFF3B82F6),
          text: Color(0xFF3B82F6),
          icon: Icons.edit_calendar_rounded,
        );
      case DayDisplayState.futureDay:
        return const _DayCellStyle(
          bg: Color(0xFFF3F4F6),
          border: Color(0xFFE5E7EB),
          text: Color(0xFF9CA3AF),
          icon: null,
        );
    }
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final systemBottom = media.padding.bottom > 0
        ? media.padding.bottom
        : media.viewPadding.bottom;
    final fabBottomPadding = systemBottom + _fabBottomOffset;
    final contentBottomPadding = fabBottomPadding + _contentBottomGap;

    return GestureDetector(
      onTap: _closeFab,
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          automaticallyImplyLeading: false,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Kalender',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Ke hari ini',
              splashRadius: 20,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              onPressed: () {
                final now = DateTime.now();
                setState(() {
                  _focusedDay = now;
                  _selectedDay = DateTime(now.year, now.month, now.day);
                });
                _loadMonthIfNeeded(now);
              },
              icon: const Icon(
                Icons.today_rounded,
                color: AppColors.textPrimary,
              ),
            ),
            IconButton(
              tooltip: 'Pengaturan hari libur',
              splashRadius: 20,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              onPressed: _showOffDaySettings,
              icon: const Icon(
                Icons.settings_rounded,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Stack(
          children: [
            ListenableBuilder(
              listenable: _store,
              builder: (context, _) {
                _dayMetaCache.clear();
                return RefreshIndicator(
                  onRefresh: _refreshCalendar,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      contentBottomPadding,
                    ),
                    children: [
                      _buildMonthSummary(),
                      const SizedBox(height: 12),
                      RepaintBoundary(child: _buildCalendarCard()),
                      const SizedBox(height: 12),
                      _buildLegend(),
                      const SizedBox(height: 12),
                      RepaintBoundary(child: _buildDayDetail()),
                    ],
                  ),
                );
              },
            ),
            Positioned(
              right: 16,
              bottom: fabBottomPadding,
              child: _buildFabMenu(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── FLOATING BUBBLE MENU ─────────────────────────────────────────────────

  Widget _buildFabMenu() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Child bubbles
        ScaleTransition(
          scale: _fabScale,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _childBubble(
                icon: Icons.notifications_active_rounded,
                label: 'Reminder',
                onTap: () {
                  _closeFab();
                  _showReminderSheet(date: _selectedDay);
                },
              ),
              const SizedBox(height: 10),
              _childBubble(
                icon: Icons.edit_calendar_rounded,
                label: 'Kegiatan Manual',
                onTap: () {
                  _closeFab();
                  _showManualActivitySheet(date: _selectedDay);
                },
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        // Main bubble
        GestureDetector(
          onTap: _toggleFab,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: RotationTransition(
              turns: _fabRotate,
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _childBubble({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, color: AppColors.primary, size: 18),
          ),
        ],
      ),
    );
  }

  // ─── MONTH SUMMARY ────────────────────────────────────────────────────────

  Widget _buildMonthSummary() {
    final stats = _store.monthStatsOf(_focusedDay);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDark.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.calendar_month_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _monthLabel(_focusedDay),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _chip('Ringkasan', AppColors.primary, AppColors.primaryLight),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              _summaryCell(
                'Hadir',
                stats.present.toString(),
                AppColors.success,
                Icons.check_circle_rounded,
              ),
              _vDivider(),
              _summaryCell(
                'Absen',
                stats.missing.toString(),
                AppColors.missing,
                Icons.warning_amber_rounded,
              ),
              _vDivider(),
              _summaryCell(
                'Libur',
                stats.offDay.toString(),
                AppColors.error,
                Icons.weekend_rounded,
              ),
              _vDivider(),
              _summaryCell(
                'Pengingat',
                stats.reminders.toString(),
                AppColors.primary,
                Icons.notifications_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _vDivider() =>
      Container(width: 1, height: 36, color: AppColors.border);

  Widget _summaryCell(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: color,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ─── CALENDAR CARD ────────────────────────────────────────────────────────

  Widget _buildCalendarCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      child: TableCalendar(
        firstDay: DateTime(2024),
        lastDay: DateTime(2030),
        focusedDay: _focusedDay,
        selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
        calendarFormat: _calendarFormat,
        availableCalendarFormats: const {
          CalendarFormat.month: 'Bulan',
          CalendarFormat.twoWeeks: '2 Mgg',
          CalendarFormat.week: 'Mgg',
        },
        onFormatChanged: (f) => setState(() => _calendarFormat = f),
        onDaySelected: (selected, focused) {
          _closeFab();
          setState(() {
            _selectedDay = selected;
            _focusedDay = focused;
          });
        },
        onPageChanged: (focused) {
          setState(() => _focusedDay = focused);
          _loadMonthIfNeeded(focused);
        },
        startingDayOfWeek: StartingDayOfWeek.monday,
        headerStyle: const HeaderStyle(
          titleCentered: true,
          formatButtonDecoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
          formatButtonTextStyle: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
          formatButtonShowsNext: false,
          titleTextStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: AppColors.textPrimary,
          ),
          leftChevronIcon: Icon(
            Icons.chevron_left_rounded,
            color: AppColors.primary,
          ),
          rightChevronIcon: Icon(
            Icons.chevron_right_rounded,
            color: AppColors.primary,
          ),
          headerPadding: EdgeInsets.symmetric(vertical: 6),
        ),
        daysOfWeekStyle: const DaysOfWeekStyle(
          weekdayStyle: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
          weekendStyle: TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
        calendarStyle: const CalendarStyle(
          outsideDaysVisible: false,
          cellMargin: EdgeInsets.all(3),
        ),
        calendarBuilders: CalendarBuilders(
          defaultBuilder: (ctx, day, _) => _buildDayCell(day),
          todayBuilder: (ctx, day, _) => _buildDayCell(day, isToday: true),
          selectedBuilder: (ctx, day, _) =>
              _buildDayCell(day, isSelected: true),
          outsideBuilder: (ctx, day, _) => const SizedBox(),
        ),
      ),
    );
  }

  Widget _buildDayCell(
    DateTime day, {
    bool isToday = false,
    bool isSelected = false,
  }) {
    final meta = _dayMetaOf(day);
    final cellStyle = _dayCellStyle(meta.state, meta.record?.status);
    final reminderCount = meta.reminderCount;
    final worklogCount = meta.worklogCount;

    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: isSelected ? AppColors.primary : cellStyle.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? AppColors.primary
              : isToday
              ? AppColors.primary
              : cellStyle.border,
          width: isToday && !isSelected ? 1.8 : 1,
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isToday || isSelected
                    ? FontWeight.bold
                    : FontWeight.w500,
                color: isSelected ? Colors.white : cellStyle.text,
              ),
            ),
          ),
          if (cellStyle.icon != null && !isSelected)
            Positioned(
              bottom: 2,
              left: 0,
              right: 0,
              child: Center(
                child: Icon(cellStyle.icon, size: 9, color: cellStyle.border),
              ),
            ),
          if (reminderCount > 0)
            Positioned(
              top: 1,
              right: 1,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white24 : AppColors.primary,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Center(
                  child: Text(
                    '$reminderCount',
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (worklogCount > 0 && !isSelected)
            Positioned(
              bottom: 2,
              left: 3,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  worklogCount.clamp(0, 3),
                  (i) => Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(right: 1.5),
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── LEGEND ───────────────────────────────────────────────────────────────

  Widget _buildLegend() {
    final items = [
      (color: AppColors.success, bg: AppColors.successLight, label: 'Hadir'),
      (color: AppColors.error, bg: AppColors.errorLight, label: 'Libur'),
      (color: AppColors.missing, bg: AppColors.missingLight, label: 'Absen'),
      (
        color: const Color(0xFF3B82F6),
        bg: const Color(0xFFEFF6FF),
        label: 'Pengecualian',
      ),
      (
        color: AppColors.textSecondary,
        bg: const Color(0xFFF3F4F6),
        label: 'Mendatang',
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        children: items.map((item) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: item.bg,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: item.color, width: 1.2),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                item.label,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  // ─── DAY DETAIL ───────────────────────────────────────────────────────────

  Widget _buildDayDetail() {
    final day = _selectedDay;
    final meta = _dayMetaOf(day);
    final record = meta.record;
    final worklogs = meta.worklogs;
    final reminders = meta.reminders;
    final state = meta.state;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.calendar_today_rounded,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  _dateFull(day),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                if (state == DayDisplayState.workedOnOffDay)
                  _chip(
                    'Masuk saat libur',
                    AppColors.success,
                    AppColors.successLight,
                  ),
                if (state == DayDisplayState.missingAttendance)
                  _chip(
                    'Belum absen',
                    AppColors.missing,
                    AppColors.missingLight,
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),

          _buildAttendanceSection(record, state, day),

          if (worklogs.isNotEmpty) ...[
            const Divider(height: 1, color: AppColors.border),
            _buildWorklogSection(worklogs),
          ],

          if (reminders.isNotEmpty) ...[
            const Divider(height: 1, color: AppColors.border),
            _buildReminderSection(reminders),
          ],

          const Divider(height: 1, color: AppColors.border),
          _buildActionRow(record, day),
        ],
      ),
    );
  }

  Widget _buildAttendanceSection(
    AttendanceRecord? record,
    DayDisplayState state,
    DateTime day,
  ) {
    if (record == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: _buildEmptyAttendance(state, day),
      );
    }

    final style = _attendanceStyle(record.status);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: style.bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(style.icon, color: style.color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      style.label,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: style.color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: record.source == AttendanceSource.face
                            ? AppColors.primaryLight
                            : AppColors.warningLight,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        record.source == AttendanceSource.face
                            ? 'Face'
                            : 'Manual',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: record.source == AttendanceSource.face
                              ? AppColors.primary
                              : AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (record.checkIn != null || record.checkOut != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (record.checkIn != null)
                  Expanded(
                    child: _timeChip(
                      Icons.login_rounded,
                      'Check-in',
                      _fmtTod(record.checkIn!),
                      AppColors.success,
                    ),
                  ),
                if (record.checkIn != null && record.checkOut != null)
                  const SizedBox(width: 10),
                if (record.checkOut != null)
                  Expanded(
                    child: _timeChip(
                      Icons.logout_rounded,
                      'Check-out',
                      _fmtTod(record.checkOut!),
                      AppColors.error,
                    ),
                  ),
              ],
            ),
            if (record.checkIn != null && record.checkOut != null) ...[
              const SizedBox(height: 8),
              _timeChip(
                Icons.schedule_rounded,
                'Total jam',
                _durationBetween(record.checkIn!, record.checkOut!),
                AppColors.primary,
                full: true,
              ),
            ],
          ],
          if (record.note != null && record.note!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.notes_rounded,
                    size: 14,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      record.note!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyAttendance(DayDisplayState state, DateTime day) {
    final isFuture = state == DayDisplayState.futureDay;
    final isMissing = state == DayDisplayState.missingAttendance;
    final isOffDay = state == DayDisplayState.offDay;

    String message;
    IconData icon;
    Color color;

    if (isFuture) {
      message = 'Hari mendatang';
      icon = Icons.calendar_today_rounded;
      color = AppColors.textSecondary;
    } else if (isOffDay) {
      message = 'Hari libur – tidak ada presensi';
      icon = Icons.weekend_rounded;
      color = AppColors.error;
    } else if (isMissing) {
      message = 'Tidak ada presensi pada hari kerja ini';
      icon = Icons.warning_amber_rounded;
      color = AppColors.missing;
    } else {
      message = 'Belum ada data presensi';
      icon = Icons.hourglass_empty_rounded;
      color = AppColors.textSecondary;
    }

    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(
          message,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildWorklogSection(List<WorklogEntry> worklogs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.work_history_rounded,
                size: 13,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              const Text(
                'Aktivitas Kerja',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${worklogs.length} entri',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...worklogs.map((wl) => _buildWorklogItem(wl)),
        ],
      ),
    );
  }

  Widget _buildWorklogItem(WorklogEntry wl) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: wl.projectColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  wl.taskName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${wl.projectName}  ·  ${wl.startTime != null ? _fmtTod(wl.startTime!) : '--'} - ${wl.endTime != null ? _fmtTod(wl.endTime!) : '--'}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            wl.duration,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReminderSection(List<ReminderEvent> reminders) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.notifications_rounded,
                size: 13,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 5),
              const Text(
                'Pengingat',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${reminders.length} acara',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...reminders.map((r) => _buildReminderItem(r)),
        ],
      ),
    );
  }

  Widget _buildReminderItem(ReminderEvent r) {
    final start = r.isAllDay
        ? 'Seharian'
        : '${_fmtDt(r.startDateTime)}${r.endDateTime != null ? ' - ${_fmtDt(r.endDateTime!)}' : ''}';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 74,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          r.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          _store.removeReminder(r);
                          NotificationService.instance.cancelReminder(r);
                          _syncReminderDelete(r);
                        },
                        child: const Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    start,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (r.description != null && r.description!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      r.description!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    children: r.reminderOffsetsInMinutes.map((m) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$m mnt',
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(AttendanceRecord? record, DateTime day) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          if (record != null) ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(day),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('Hapus'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: () =>
                    _showManualEntryModal(preselected: day, existing: record),
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: const Text('Edit Presensi'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ] else ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showQuickActionModal(day),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Tandai Cepat'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _showManualEntryModal(preselected: day),
                icon: const Icon(Icons.edit_calendar_rounded, size: 16),
                label: const Text('Input Manual'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── MANUAL ACTIVITY SHEET (new worklog from calendar) ────────────────────

  void _showManualActivitySheet({required DateTime date}) async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;

    List<Project> projects = [];
    bool loadingProjects = true;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _ManualActivitySheet(
          initialDate: date,
          userId: uid,
          projects: projects,
          loadingProjects: loadingProjects,
          onFetchProjects: () => ProjectService.instance.fetchProjects(uid),
          onSave: (entry) async {
            try {
              final saved = await WorklogService.instance.createWorklog(
                entry,
                uid,
              );
              // Pop first, then update store to avoid _dependents assertion
              if (ctx.mounted) Navigator.pop(ctx);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _store.addWorklog(saved);
              });
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: AppColors.success,
                    duration: Duration(seconds: 2),
                    content: Text('Kegiatan berhasil disimpan'),
                  ),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: AppColors.error,
                    duration: const Duration(seconds: 8),
                    content: Text('Gagal menyimpan kegiatan: $e'),
                  ),
                );
              }
            }
          },
        );
      },
    );
  }

  // ─── QUICK ACTION MODAL ───────────────────────────────────────────────────

  void _showQuickActionModal(DateTime date) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sheetHandle(),
              const SizedBox(height: 16),
              Text(
                'Tandai ${_dateFull(date)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Pilih status kehadiran',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              _quickTile(
                AttendanceStatus.leave,
                subtitle: 'Cuti tahunan, izin pribadi, dll.',
                onTap: () {
                  Navigator.pop(ctx);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _markAttendance(date, AttendanceStatus.leave);
                  });
                },
              ),
              const SizedBox(height: 8),
              _quickTile(
                AttendanceStatus.sick,
                subtitle: 'Sakit dengan/tanpa surat dokter.',
                onTap: () {
                  Navigator.pop(ctx);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _markAttendance(date, AttendanceStatus.sick);
                  });
                },
              ),
              const SizedBox(height: 8),
              _quickTile(
                AttendanceStatus.holiday,
                subtitle: 'Libur nasional / event perusahaan.',
                onTap: () {
                  Navigator.pop(ctx);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _markAttendance(date, AttendanceStatus.holiday);
                  });
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () {
                  Navigator.pop(ctx);
                  _showManualEntryModal(preselected: date);
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.edit_calendar_rounded,
                        color: AppColors.primary,
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Input Manual (form lengkap)',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                  ),
                  child: const Text(
                    'Batal',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickTile(
    AttendanceStatus status, {
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final s = _attendanceStyle(status);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: s.bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(s.icon, color: s.color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tandai ${s.label}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  // ─── MANUAL ENTRY MODAL (attendance) ──────────────────────────────────────

  void _showManualEntryModal({
    DateTime? preselected,
    AttendanceRecord? existing,
  }) {
    DateTime date = preselected ?? existing?.date ?? DateTime.now();
    AttendanceStatus status = existing?.status ?? AttendanceStatus.present;
    TimeOfDay? checkIn = existing?.checkIn;
    TimeOfDay? checkOut = existing?.checkOut;
    final notesCtrl = TextEditingController(text: existing?.note ?? '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final needsTime = status == AttendanceStatus.present;
          return Padding(
            padding: EdgeInsets.only(
              top: 12,
              left: 20,
              right: 20,
              bottom: _sheetBottomPadding(ctx),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sheetHandle(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.edit_calendar_rounded,
                          color: AppColors.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        existing == null
                            ? 'Input Manual Absensi'
                            : 'Edit Absensi',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _label('Tanggal'),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(2024),
                        lastDate: DateTime(2030),
                      );
                      if (picked != null) setSheet(() => date = picked);
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: _fieldBox(
                      icon: Icons.calendar_today_rounded,
                      text: _dateFull(date),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _label('Tipe'),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<AttendanceStatus>(
                        value: status,
                        isExpanded: true,
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textSecondary,
                        ),
                        items: AttendanceStatus.values.map((s) {
                          final st = _attendanceStyle(s);
                          return DropdownMenuItem(
                            value: s,
                            child: Row(
                              children: [
                                Icon(st.icon, size: 16, color: st.color),
                                const SizedBox(width: 10),
                                Text(
                                  st.label,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) setSheet(() => status = v);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (needsTime) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Check-in'),
                              const SizedBox(height: 6),
                              _timeBtn(
                                ctx,
                                checkIn,
                                (t) => setSheet(() => checkIn = t),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Check-out'),
                              const SizedBox(height: 6),
                              _timeBtn(
                                ctx,
                                checkOut,
                                (t) => setSheet(() => checkOut = t),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  _label('Catatan (opsional)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    maxLength: 200,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Tambahkan catatan...',
                      hintStyle: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        final capturedDate = date;
                        final capturedStatus = status;
                        final capturedCheckIn = needsTime ? checkIn : null;
                        final capturedCheckOut = needsTime ? checkOut : null;
                        final capturedNote = notesCtrl.text.trim().isEmpty
                            ? null
                            : notesCtrl.text.trim();
                        final capturedExisting = existing;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _markAttendance(
                            capturedDate,
                            capturedStatus,
                            checkIn: capturedCheckIn,
                            checkOut: capturedCheckOut,
                            note: capturedNote,
                            existing: capturedExisting,
                          );
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        existing == null ? 'Simpan' : 'Perbarui',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).then((_) => notesCtrl.dispose());
  }

  // ─── REMINDER SHEET ───────────────────────────────────────────────────────

  void _showReminderSheet({required DateTime date, ReminderEvent? existing}) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    DateTime startDate =
        existing?.startDateTime ??
        DateTime(date.year, date.month, date.day, 9, 0);
    TimeOfDay startTime = TimeOfDay(
      hour: startDate.hour,
      minute: startDate.minute,
    );
    bool isAllDay = existing?.isAllDay ?? false;
    List<int> offsets = List.from(
      existing?.reminderOffsetsInMinutes ??
          _store.settings.defaultReminderOffsetsInMinutes,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            top: 12,
            left: 20,
            right: 20,
            bottom: _sheetBottomPadding(ctx),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sheetHandle(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.notifications_active_rounded,
                        color: AppColors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      existing == null ? 'Tambah Pengingat' : 'Edit Pengingat',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _label('Judul*'),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                    hintText: 'Mis. Sprint Review',
                    hintStyle: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _label('Deskripsi (opsional)'),
                const SizedBox(height: 6),
                TextField(
                  controller: descCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: 'Tambahkan detail...',
                    hintStyle: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label('Tanggal'),
                          const SizedBox(height: 6),
                          InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: startDate,
                                firstDate: DateTime(2024),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) {
                                setSheet(() {
                                  startDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                    startTime.hour,
                                    startTime.minute,
                                  );
                                });
                              }
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: _fieldBox(
                              icon: Icons.calendar_today_rounded,
                              text:
                                  '${startDate.day}/${startDate.month}/${startDate.year}',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!isAllDay) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Waktu'),
                            const SizedBox(height: 6),
                            _timeBtn(ctx, startTime, (t) {
                              setSheet(() {
                                startTime = t;
                                startDate = DateTime(
                                  startDate.year,
                                  startDate.month,
                                  startDate.day,
                                  t.hour,
                                  t.minute,
                                );
                              });
                            }),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Seharian',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: isAllDay,
                      onChanged: (v) => setSheet(() => isAllDay = v),
                      activeThumbColor: AppColors.primary,
                      activeTrackColor: AppColors.primaryLight,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _label('Ingatkan sebelum'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [5, 10, 15, 30, 60].map((m) {
                    final selected = offsets.contains(m);
                    return GestureDetector(
                      onTap: () {
                        setSheet(() {
                          if (selected) {
                            offsets = offsets.where((v) => v != m).toList();
                          } else {
                            offsets = [...offsets, m]..sort();
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.primary
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? AppColors.primary
                                : AppColors.border,
                          ),
                        ),
                        child: Text(
                          m < 60 ? '$m mnt' : '${m ~/ 60} jam',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () async {
                      if (titleCtrl.text.trim().isEmpty) return;
                      final uid = AuthService.instance.currentUserId;
                      if (uid == null) return;

                      final event = ReminderEvent(
                        id: existing?.id ?? _uuid.v4(),
                        title: titleCtrl.text.trim(),
                        description: descCtrl.text.trim().isEmpty
                            ? null
                            : descCtrl.text.trim(),
                        startDateTime: startDate,
                        isAllDay: isAllDay,
                        reminderOffsetsInMinutes: offsets.isEmpty
                            ? [15]
                            : offsets,
                      );

                      try {
                        ReminderEvent saved;
                        if (existing != null) {
                          saved = await ReminderService.instance.upsertReminder(
                            event,
                            uid,
                          );
                        } else {
                          saved = await ReminderService.instance.upsertReminder(
                            event,
                            uid,
                          );
                        }
                        // Pop first, then update store to avoid _dependents assertion
                        if (ctx.mounted) Navigator.pop(ctx);
                        NotificationService.instance.scheduleReminder(saved);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (existing != null) {
                            _store.updateReminder(saved);
                          } else {
                            _store.addReminder(saved);
                          }
                          NotificationProvider.instance.refresh();
                        });
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppColors.error,
                              duration: const Duration(seconds: 8),
                              content: Text('Gagal menyimpan pengingat: $e'),
                            ),
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      existing == null ? 'Simpan Pengingat' : 'Perbarui',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).then((_) {
      titleCtrl.dispose();
      descCtrl.dispose();
    });
  }

  // ─── OFF-DAY SETTINGS ─────────────────────────────────────────────────────

  void _showOffDaySettings() {
    final settings = _store.settings;
    Set<int> offDays = Set.from(settings.offDays);
    bool autoMissing = settings.autoMarkMissingAttendance;

    const dayNames = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sheetHandle(),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.settings_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Pengaturan Jadwal',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Hari Libur Mingguan',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Hari-hari ini akan ditandai merah jika tidak ada presensi',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(7, (i) {
                  final weekday = i + 1;
                  final selected = offDays.contains(weekday);
                  return GestureDetector(
                    onTap: () => setSheet(() {
                      if (selected) {
                        offDays.remove(weekday);
                      } else {
                        offDays.add(weekday);
                      }
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.error : AppColors.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? AppColors.error : AppColors.border,
                        ),
                      ),
                      child: Text(
                        dayNames[i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tandai Otomatis Absen',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Hari kerja lampau tanpa presensi ditandai oranye',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: autoMissing,
                    onChanged: (v) => setSheet(() => autoMissing = v),
                    activeThumbColor: AppColors.primary,
                    activeTrackColor: AppColors.primaryLight,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    _store.updateSettings(
                      settings.copyWith(
                        offDays: offDays,
                        autoMarkMissingAttendance: autoMissing,
                      ),
                    );
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Simpan Pengaturan',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── CRUD ─────────────────────────────────────────────────────────────────

  Future<void> _markAttendance(
    DateTime date,
    AttendanceStatus status, {
    TimeOfDay? checkIn,
    TimeOfDay? checkOut,
    String? note,
    AttendanceRecord? existing,
  }) async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    final d = DateTime(date.year, date.month, date.day);
    final record = AttendanceRecord(
      id: existing?.id ?? _uuid.v4(),
      date: d,
      source: AttendanceSource.manual,
      status: status,
      checkIn: checkIn,
      checkOut: checkOut,
      note: note,
    );
    try {
      final saved = await AttendanceService.instance.upsertRecord(record, uid);
      _store.setAttendance(saved);
      NotificationProvider.instance.refresh();
      setState(() {
        _selectedDay = d;
        _focusedDay = d;
      });
      final style = _attendanceStyle(status);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: style.color,
            duration: const Duration(seconds: 2),
            content: Text('Ditandai sebagai ${style.label} · ${_dateFull(d)}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 8),
            content: Text('Gagal menyimpan presensi: $e'),
          ),
        );
      }
    }
  }

  void _confirmDelete(DateTime date) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Hapus data presensi?'),
        content: Text(
          'Data untuk ${_dateFull(date)} akan dihapus.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final uid = AuthService.instance.currentUserId;
              if (uid == null) return;
              try {
                await AttendanceService.instance.deleteRecord(uid, date);
              } catch (_) {}
              _store.removeAttendance(date);
              NotificationProvider.instance.refresh();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncReminderDelete(ReminderEvent r) async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    try {
      await ReminderService.instance.deleteReminder(r.id, uid);
      NotificationProvider.instance.refresh();
    } catch (_) {}
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────────

  Widget _sheetHandle() => Center(
    child: Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.textSecondary,
    ),
  );

  double _sheetBottomPadding(BuildContext context) {
    final media = MediaQuery.of(context);
    return media.viewInsets.bottom > 0
        ? media.viewInsets.bottom + 20
        : (media.padding.bottom > 0
                  ? media.padding.bottom
                  : media.viewPadding.bottom) +
              28;
  }

  Widget _fieldBox({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeBtn(
    BuildContext ctx,
    TimeOfDay? value,
    ValueChanged<TimeOfDay> onPick,
  ) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: ctx,
          initialTime: value ?? TimeOfDay.now(),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        );
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: _fieldBox(
        icon: Icons.access_time_rounded,
        text: value == null ? '--:--' : _fmtTod(value),
      ),
    );
  }

  Widget _timeChip(
    IconData icon,
    String label,
    String value,
    Color color, {
    bool full = false,
  }) {
    return Container(
      width: full ? double.infinity : null,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  _CalendarDayMeta _dayMetaOf(DateTime day) {
    final key = AppStore.dateKey(day);
    final cached = _dayMetaCache[key];
    if (cached != null) return cached;

    final meta = _CalendarDayMeta(
      state: _store.dayStateOf(day),
      record: _store.attendanceOf(day),
      worklogs: _store.worklogsOf(day),
      reminders: _store.remindersOf(day),
    );
    _dayMetaCache[key] = meta;
    return meta;
  }

  // ─── FORMAT ───────────────────────────────────────────────────────────────

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _fmtDt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _durationBetween(TimeOfDay a, TimeOfDay b) {
    final mins = (b.hour * 60 + b.minute) - (a.hour * 60 + a.minute);
    if (mins <= 0) return '0m';
    final h = mins ~/ 60;
    final m = mins % 60;
    return h > 0 ? '${h}j ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

  String _dateFull(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    const days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _monthLabel(DateTime d) {
    const months = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _CalendarDayMeta {
  const _CalendarDayMeta({
    required this.state,
    required this.record,
    required this.worklogs,
    required this.reminders,
  });

  final DayDisplayState state;
  final AttendanceRecord? record;
  final List<WorklogEntry> worklogs;
  final List<ReminderEvent> reminders;

  int get worklogCount => worklogs.length;
  int get reminderCount => reminders.length;
}

// ─── MANUAL ACTIVITY SHEET WIDGET ─────────────────────────────────────────────

class _ManualActivitySheet extends StatefulWidget {
  final DateTime initialDate;
  final String userId;
  final List<Project> projects;
  final bool loadingProjects;
  final Future<List<Project>> Function() onFetchProjects;
  final Future<void> Function(WorklogEntry entry) onSave;

  const _ManualActivitySheet({
    required this.initialDate,
    required this.userId,
    required this.projects,
    required this.loadingProjects,
    required this.onFetchProjects,
    required this.onSave,
  });

  @override
  State<_ManualActivitySheet> createState() => _ManualActivitySheetState();
}

class _ManualActivitySheetState extends State<_ManualActivitySheet> {
  static const _uuid = Uuid();
  late DateTime _date;
  final _taskCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  Project? _selectedProject;
  List<Project> _projects = [];
  bool _loadingProjects = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _loadProjects();
  }

  @override
  void dispose() {
    _taskCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    try {
      final list = await widget.onFetchProjects();
      if (mounted) {
        setState(() {
          _projects = list;
          _loadingProjects = false;
          if (list.isNotEmpty) _selectedProject = list.first;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingProjects = false);
    }
  }

  String _duration() {
    if (_startTime == null || _endTime == null) return '';
    final mins =
        (_endTime!.hour * 60 + _endTime!.minute) -
        (_startTime!.hour * 60 + _startTime!.minute);
    if (mins <= 0) return '';
    final h = mins ~/ 60;
    final m = mins % 60;
    return h > 0 ? '${h}j ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _dateFull(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    const days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final dur = _duration();

    return Padding(
      padding: EdgeInsets.only(
        top: 12,
        left: 20,
        right: 20,
        bottom: _sheetBottomPadding(context),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Title
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.edit_calendar_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Tambah Kegiatan Manual',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Nama tugas
            _label('Nama Tugas*'),
            const SizedBox(height: 6),
            TextField(
              controller: _taskCtrl,
              decoration: _inputDeco('Mis. Desain halaman login'),
            ),
            const SizedBox(height: 14),

            // Tanggal
            _label('Tanggal'),
            const SizedBox(height: 6),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2024),
                  lastDate: DateTime(2030),
                );
                if (picked != null) setState(() => _date = picked);
              },
              borderRadius: BorderRadius.circular(10),
              child: _fieldBox(
                icon: Icons.calendar_today_rounded,
                text: _dateFull(_date),
              ),
            ),
            const SizedBox(height: 14),

            // Waktu
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Mulai'),
                      const SizedBox(height: 6),
                      _timeBtn(
                        _startTime,
                        (t) => setState(() => _startTime = t),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Selesai'),
                      const SizedBox(height: 6),
                      _timeBtn(_endTime, (t) => setState(() => _endTime = t)),
                    ],
                  ),
                ),
              ],
            ),
            if (dur.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.schedule_rounded,
                      size: 13,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Durasi: $dur',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),

            // Proyek
            _label('Proyek'),
            const SizedBox(height: 6),
            if (_loadingProjects)
              const SizedBox(
                height: 48,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_projects.isEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Text(
                  'Belum ada proyek. Buat proyek di Tracker.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<Project>(
                    value: _selectedProject,
                    isExpanded: true,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppColors.textSecondary,
                    ),
                    items: _projects.map((p) {
                      return DropdownMenuItem(
                        value: p,
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: p.color,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              p.name,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedProject = v);
                    },
                  ),
                ),
              ),
            const SizedBox(height: 14),

            // Catatan
            _label('Catatan (opsional)'),
            const SizedBox(height: 6),
            TextField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: _inputDeco('Tambahkan catatan...'),
            ),
            const SizedBox(height: 20),

            // Save
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Simpan Kegiatan',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_taskCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nama tugas tidak boleh kosong')),
      );
      return;
    }

    setState(() => _saving = true);

    final entry = WorklogEntry(
      id: _uuid.v4(),
      date: DateTime(_date.year, _date.month, _date.day),
      taskName: _taskCtrl.text.trim(),
      projectName: _selectedProject?.name ?? 'Tanpa Proyek',
      projectColor: _selectedProject?.color ?? AppColors.textSecondary,
      startTime: _startTime,
      endTime: _endTime,
      duration: _duration(),
    );

    await widget.onSave(entry);

    if (mounted) setState(() => _saving = false);
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.textSecondary,
    ),
  );

  double _sheetBottomPadding(BuildContext context) {
    final media = MediaQuery.of(context);
    return media.viewInsets.bottom > 0
        ? media.viewInsets.bottom + 20
        : (media.padding.bottom > 0
                  ? media.padding.bottom
                  : media.viewPadding.bottom) +
              28;
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
    filled: true,
    fillColor: AppColors.background,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  );

  Widget _fieldBox({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeBtn(TimeOfDay? value, ValueChanged<TimeOfDay> onPick) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: value ?? TimeOfDay.now(),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        );
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: _fieldBox(
        icon: Icons.access_time_rounded,
        text: value == null ? '--:--' : _fmtTod(value),
      ),
    );
  }
}

// ─── STATUS STYLE ─────────────────────────────────────────────────────────────

class _StatusStyle {
  final String label;
  final IconData icon;
  final Color color;
  final Color bg;
  const _StatusStyle({
    required this.label,
    required this.icon,
    required this.color,
    required this.bg,
  });
}

// ─── DAY CELL STYLE ───────────────────────────────────────────────────────────

class _DayCellStyle {
  final Color bg;
  final Color border;
  final Color text;
  final IconData? icon;
  final String? extraLabel;
  const _DayCellStyle({
    required this.bg,
    required this.border,
    required this.text,
    this.icon,
    this.extraLabel,
  });
}
