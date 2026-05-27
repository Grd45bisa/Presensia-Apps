import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../shared/models/app_models.dart';
import '../../../shared/services/attendance_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/pdf/report_pdf_service.dart';
import '../../../shared/services/reminder_service.dart';
import '../../../shared/services/schedule_settings_service.dart';
import '../../../shared/services/worklog_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _authService = AuthService.instance;
  final _attendanceService = AttendanceService.instance;
  final _reminderService = ReminderService.instance;
  final _worklogService = WorklogService.instance;
  final _settingsService = ScheduleSettingsService.instance;

  late DateTime _rangeStart;
  late DateTime _rangeEnd;
  late _ReportRangeData _reportData;

  bool _isLoading = true;
  String? _errorMessage;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _rangeStart = DateTime(now.year, now.month, 1);
    _rangeEnd = DateTime(now.year, now.month, now.day);
    _reportData = _ReportRangeData.empty(_rangeStart, _rangeEnd);
    _loadReportData();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final systemBottom = media.padding.bottom > 0
        ? media.padding.bottom
        : media.viewPadding.bottom;
    final contentBottomPadding = systemBottom + 112.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        automaticallyImplyLeading: false,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Laporan',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w900,
            fontSize: 18,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _showExportInfo,
            splashRadius: 20,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            icon: const Icon(
              Icons.picture_as_pdf_rounded,
              color: AppColors.textPrimary,
            ),
            tooltip: 'Export PDF',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadReportData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(16, 14, 16, contentBottomPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isLoading) ...[
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 12),
              ],
              if (_errorMessage != null) ...[
                _buildStatusCard(
                  title: 'Data laporan belum sepenuhnya tersedia',
                  message: _errorMessage!,
                  icon: Icons.cloud_off_rounded,
                  color: AppColors.warning,
                  actionLabel: 'Coba Lagi',
                  onAction: _loadReportData,
                ),
                const SizedBox(height: 14),
              ],
              _buildHeroCard(_reportData),
              const SizedBox(height: 14),
              _buildRangeFilterCard(),
              const SizedBox(height: 14),
              _buildStatsGrid(_reportData),
              const SizedBox(height: 14),
              RepaintBoundary(child: _buildBarChartCard(_reportData)),
              const SizedBox(height: 14),
              RepaintBoundary(child: _buildDistributionCard(_reportData)),
              const SizedBox(height: 14),
              _buildInsightCard(_reportData),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard({
    required String title,
    required String message,
    required IconData icon,
    required Color color,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              height: 1.4,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroCard(_ReportRangeData data) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x221565C0),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0x1FFFFFFF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _dateRangeLabel(data.startDate, data.endDate),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _formatDurationCompact(data.totalWorkDuration),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 30,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Total jam kerja dari tracker pada rentang tanggal yang dipilih',
            style: TextStyle(
              color: Color(0xD9FFFFFF),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _heroMetric(
                  'Target',
                  '${data.presentDays}/${data.workdayTarget}',
                  Icons.calendar_today_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _heroMetric(
                  'Rata-rata',
                  data.averageWorkHoursLabel,
                  Icons.schedule_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _heroMetric(
                  'Entry',
                  data.totalEntries.toString(),
                  Icons.work_history_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroMetric(String label, String value, IconData icon) {
    return Container(
      constraints: const BoxConstraints(minHeight: 98),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x26FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildRangeFilterCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.filter_alt_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Rentang Tanggal',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Pilih tanggal mulai dan tanggal selesai, misalnya periode gajian 7 Apr sampai 6 Mei.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildDateField(
                  label: 'Mulai',
                  value: _dateShort(_rangeStart),
                  onTap: () => _pickRangeDate(isStart: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildDateField(
                  label: 'Selesai',
                  value: _dateShort(_rangeEnd),
                  onTap: () => _pickRangeDate(isStart: false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateField({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.calendar_today_rounded,
                  size: 15,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(_ReportRangeData data) {
    final items = [
      (
        label: 'Hari Hadir',
        value: '${data.presentDays} / ${data.workdayTarget}',
        icon: Icons.calendar_today_rounded,
        color: AppColors.success,
        helper: '${data.attendanceRateLabel} dari target kerja',
      ),
      (
        label: 'Total Jam',
        value: _formatDurationCompact(data.totalWorkDuration),
        icon: Icons.schedule_rounded,
        color: AppColors.primary,
        helper: '${data.totalEntries} aktivitas kerja tercatat',
      ),
      (
        label: 'Ketepatan',
        value: data.punctualityLabel,
        icon: Icons.alarm_on_rounded,
        color: AppColors.warning,
        helper: '${data.onTimeCount}/${data.daysWithCheckIn} hari tepat waktu',
      ),
      (
        label: 'Rata-rata',
        value: data.averageWorkHoursLabel,
        icon: Icons.insights_rounded,
        color: AppColors.primaryDark,
        helper: 'Jam kerja rata-rata per hari aktif',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: items.map((item) {
            return SizedBox(
              width: cardWidth,
              child: _buildStatCard(
                item.label,
                item.value,
                item.icon,
                item.color,
                item.helper,
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
    String helper,
  ) {
    return Container(
      constraints: const BoxConstraints(minHeight: 126),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const Spacer(),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            helper,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondary,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildBarChartCard(_ReportRangeData data) {
    final maxHours = data.buckets.fold<double>(
      0,
      (prev, bucket) => bucket.hours > prev ? bucket.hours : prev,
    );
    final chartMaxY = maxHours <= 4
        ? 4.0
        : ((maxHours / 2).ceil() * 2).toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Jam Kerja per Periode 7 Hari',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${data.totalDays} hari',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Cocok untuk memantau periode kerja khusus seperti 7 April sampai 6 Mei.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final chartWidth = data.buckets.length <= 5
                  ? constraints.maxWidth
                  : data.buckets.length * 58.0;
              final barWidth = data.buckets.length > 8 ? 16.0 : 22.0;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: SizedBox(
                  width: chartWidth.clamp(constraints.maxWidth, 1000.0),
                  height: 190,
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: chartMaxY,
                      barTouchData: BarTouchData(enabled: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: chartMaxY <= 4 ? 2 : 4,
                        getDrawingHorizontalLine: (_) => const FlLine(
                          color: AppColors.border,
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: chartMaxY <= 4 ? 2 : 4,
                            reservedSize: 30,
                            getTitlesWidget: (value, _) => Text(
                              '${value.toInt()}j',
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, _) {
                              final i = value.toInt();
                              if (i < 0 || i >= data.buckets.length) {
                                return const SizedBox();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  data.buckets[i].shortLabel,
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      barGroups: data.buckets.asMap().entries.map((entry) {
                        final isPeak =
                            entry.value.hours == data.peakBucketHours &&
                            data.peakBucketHours > 0;
                        return _bar(
                          entry.key,
                          entry.value.hours,
                          isPeak: isPeak,
                          width: barWidth,
                        );
                      }).toList(),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  BarChartGroupData _bar(
    int x,
    double y, {
    bool isPeak = false,
    double width = 22,
  }) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          width: width,
          color: isPeak ? AppColors.success : AppColors.primary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
        ),
      ],
    );
  }

  Widget _buildDistributionCard(_ReportRangeData data) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Komposisi Kehadiran',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Distribusi status kehadiran berdasarkan rentang tanggal yang dipilih.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          _progressItem(
            'Hadir',
            data.presentRatio,
            AppColors.success,
            '${data.presentDays} hari',
          ),
          const SizedBox(height: 12),
          _progressItem(
            'Libur',
            data.offDayRatio,
            AppColors.error,
            '${data.offDays} hari',
          ),
          const SizedBox(height: 12),
          _progressItem(
            'Absen',
            data.missingRatio,
            AppColors.warning,
            '${data.missingDays} hari',
          ),
          const SizedBox(height: 12),
          _progressItem(
            'Pengingat',
            data.reminderRatio,
            AppColors.primary,
            '${data.reminders} acara',
          ),
        ],
      ),
    );
  }

  Widget _progressItem(
    String label,
    double value,
    Color color,
    String caption,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              caption,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: AppColors.border,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  Widget _buildInsightCard(_ReportRangeData data) {
    final insights = <({IconData icon, Color color, String label})>[
      (
        icon: Icons.auto_graph_rounded,
        color: AppColors.primary,
        label:
            'Periode tersibuk: ${data.peakBucketLabel} (${data.peakBucketHoursLabel})',
      ),
      (
        icon: Icons.login_rounded,
        color: AppColors.success,
        label:
            'Hari tepat waktu: ${data.onTimeCount} dari ${data.daysWithCheckIn}',
      ),
      (
        icon: Icons.notifications_active_rounded,
        color: AppColors.warning,
        label: 'Pengingat aktif di periode ini: ${data.reminders} acara',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Insight Singkat',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ringkasan cepat dari attendance, tracker, dan pengingat pada periode ini.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          ...insights.map(
            (item) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: item.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(item.icon, size: 18, color: item.color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickRangeDate({required bool isStart}) async {
    final initialDate = isStart ? _rangeStart : _rangeEnd;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
    );
    if (picked == null) {
      return;
    }

    setState(() {
      if (isStart) {
        _rangeStart = _normalizeDate(picked);
        if (_rangeStart.isAfter(_rangeEnd)) {
          _rangeEnd = _rangeStart;
        }
      } else {
        _rangeEnd = _normalizeDate(picked);
        if (_rangeEnd.isBefore(_rangeStart)) {
          _rangeStart = _rangeEnd;
        }
      }
      _reportData = _ReportRangeData.empty(_rangeStart, _rangeEnd);
    });

    await _loadReportData();
  }

  Future<void> _loadReportData() async {
    final serial = ++_loadSerial;
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final userId = _authService.currentUserId;
      if (userId == null) {
        throw Exception('Belum ada sesi login aktif untuk mengambil laporan.');
      }
      final start = _rangeStart;
      final end = _rangeEnd;

      final results = await Future.wait([
        _settingsService.fetchSettings(userId),
        _attendanceService.fetchRecordsInRange(userId, start, end),
        _reminderService.fetchRemindersInRange(userId, start, end),
        _worklogService.fetchWorklogsInRange(userId, start, end),
      ]);

      final settings = results[0] as WorkScheduleSettings;
      final attendance = results[1] as List<AttendanceRecord>;
      final reminders = results[2] as List<ReminderEvent>;
      final worklogs = results[3] as List<WorklogEntry>;

      final reportData = _reportDataFromSources(
        start: start,
        end: end,
        settings: settings,
        attendance: attendance,
        reminders: reminders,
        worklogs: worklogs,
      );

      if (!mounted || serial != _loadSerial) {
        return;
      }

      setState(() {
        _reportData = reportData;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || serial != _loadSerial) {
        return;
      }

      setState(() {
        _reportData = _ReportRangeData.empty(_rangeStart, _rangeEnd);
        _errorMessage = _friendlyError(error);
        _isLoading = false;
      });
    }
  }

  _ReportRangeData _reportDataFromSources({
    required DateTime start,
    required DateTime end,
    required WorkScheduleSettings settings,
    required List<AttendanceRecord> attendance,
    required List<ReminderEvent> reminders,
    required List<WorklogEntry> worklogs,
  }) {
    final startDate = _normalizeDate(start);
    final endDate = _normalizeDate(end);

    final attendanceByDate = <String, AttendanceRecord>{
      for (final record in attendance) _dateKey(record.date): record,
    };

    int workdayTarget = 0;
    int presentDays = 0;
    int missingDays = 0;
    int offDays = 0;
    int onTimeCount = 0;
    int daysWithCheckIn = 0;

    for (
      var date = startDate;
      !date.isAfter(endDate);
      date = date.add(const Duration(days: 1))
    ) {
      final isOffDay = settings.offDays.contains(date.weekday);
      if (!isOffDay) {
        workdayTarget++;
      }

      final dayState = _dayStateOf(
        day: date,
        settings: settings,
        record: attendanceByDate[_dateKey(date)],
      );

      switch (dayState) {
        case DayDisplayState.presentWorkday:
        case DayDisplayState.workedOnOffDay:
          presentDays++;
          break;
        case DayDisplayState.missingAttendance:
          missingDays++;
          break;
        case DayDisplayState.offDay:
          offDays++;
          break;
        case DayDisplayState.manualException:
        case DayDisplayState.futureDay:
          break;
      }

      final record = attendanceByDate[_dateKey(date)];
      if (record?.checkIn != null) {
        daysWithCheckIn++;
        final checkIn = record!.checkIn!;
        final isOnTime =
            checkIn.hour < 8 || (checkIn.hour == 8 && checkIn.minute <= 15);
        if (isOnTime) {
          onTimeCount++;
        }
      }
    }

    final sortedWorklogs = [...worklogs]
      ..sort((a, b) => a.date.compareTo(b.date));

    Duration totalWorkDuration = Duration.zero;
    final bucketMap = <DateTime, Duration>{};

    for (
      var bucketStart = startDate;
      !bucketStart.isAfter(endDate);
      bucketStart = bucketStart.add(const Duration(days: 7))
    ) {
      bucketMap[bucketStart] = Duration.zero;
    }

    for (final log in sortedWorklogs) {
      final duration = _worklogDuration(log);
      totalWorkDuration += duration;

      final daysFromStart = _normalizeDate(
        log.date,
      ).difference(startDate).inDays;
      final bucketOffset = (daysFromStart ~/ 7) * 7;
      final bucketStart = startDate.add(Duration(days: bucketOffset));
      bucketMap[bucketStart] =
          (bucketMap[bucketStart] ?? Duration.zero) + duration;
    }

    final buckets = bucketMap.entries.map((entry) {
      final bucketStart = entry.key;
      final bucketEnd =
          bucketStart.add(const Duration(days: 6)).isAfter(endDate)
          ? endDate
          : bucketStart.add(const Duration(days: 6));
      return _RangeBucket(
        start: bucketStart,
        end: bucketEnd,
        hours: entry.value.inMinutes / 60,
      );
    }).toList();

    final totalDistributionBase =
        (presentDays + missingDays + offDays + reminders.length).clamp(1, 9999);
    final peakBucketHours = buckets.fold<double>(
      0,
      (prev, bucket) => bucket.hours > prev ? bucket.hours : prev,
    );
    final peakBucket = buckets.firstWhere(
      (bucket) => bucket.hours == peakBucketHours,
      orElse: () => _RangeBucket(start: startDate, end: endDate, hours: 0),
    );

    return _ReportRangeData(
      startDate: startDate,
      endDate: endDate,
      presentDays: presentDays,
      workdayTarget: workdayTarget,
      missingDays: missingDays,
      offDays: offDays,
      reminders: reminders.length,
      totalEntries: sortedWorklogs.length,
      totalWorkDuration: totalWorkDuration,
      onTimeCount: onTimeCount,
      daysWithCheckIn: daysWithCheckIn,
      totalDays: endDate.difference(startDate).inDays + 1,
      buckets: buckets,
      peakBucketHours: peakBucketHours,
      peakBucketLabel: _bucketLabel(peakBucket.start, peakBucket.end),
      presentRatio: presentDays / totalDistributionBase,
      missingRatio: missingDays / totalDistributionBase,
      offDayRatio: offDays / totalDistributionBase,
      reminderRatio: reminders.length / totalDistributionBase,
    );
  }

  DayDisplayState _dayStateOf({
    required DateTime day,
    required WorkScheduleSettings settings,
    required AttendanceRecord? record,
  }) {
    final todayNorm = _normalizeDate(DateTime.now());
    final dayNorm = _normalizeDate(day);
    final isOffDay = settings.offDays.contains(day.weekday);
    final isFuture = dayNorm.isAfter(todayNorm);

    if (record != null) {
      if (record.status == AttendanceStatus.present) {
        return isOffDay
            ? DayDisplayState.workedOnOffDay
            : DayDisplayState.presentWorkday;
      }
      return DayDisplayState.manualException;
    }

    if (isOffDay) {
      return DayDisplayState.offDay;
    }
    if (isFuture) {
      return DayDisplayState.futureDay;
    }

    final isToday = dayNorm == todayNorm;
    if (!isToday && settings.autoMarkMissingAttendance) {
      return DayDisplayState.missingAttendance;
    }
    return DayDisplayState.futureDay;
  }

  Duration _worklogDuration(WorklogEntry entry) {
    if (entry.startTime == null || entry.endTime == null) {
      return Duration.zero;
    }

    final start = DateTime(
      entry.date.year,
      entry.date.month,
      entry.date.day,
      entry.startTime!.hour,
      entry.startTime!.minute,
    );
    var end = DateTime(
      entry.date.year,
      entry.date.month,
      entry.date.day,
      entry.endTime!.hour,
      entry.endTime!.minute,
    );
    if (end.isBefore(start)) {
      end = end.add(const Duration(days: 1));
    }
    return end.difference(start);
  }

  DateTime _normalizeDate(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('Belum ada sesi login aktif')) {
      return 'Login dulu supaya data laporan bisa ditarik dari database.';
    }
    if (message.contains('Supabase') || message.contains('Client')) {
      return 'Koneksi database belum siap. Coba jalankan ulang aplikasi atau periksa konfigurasi Supabase.';
    }
    return 'Gagal memuat data laporan dari database. Tarik layar ke bawah untuk mencoba lagi.';
  }

  String _dateShort(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agt',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _dateRangeLabel(DateTime start, DateTime end) =>
      '${_dateShort(start)} - ${_dateShort(end)}';

  String _bucketLabel(DateTime start, DateTime end) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agt',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    if (start.month == end.month) {
      return '${start.day}-${end.day} ${months[start.month - 1]}';
    }
    return '${start.day} ${months[start.month - 1]}-${end.day} ${months[end.month - 1]}';
  }

  String _formatDurationCompact(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours == 0) {
      return '${minutes}m';
    }
    if (minutes == 0) {
      return '${hours}j';
    }
    return '${hours}j ${minutes.toString().padLeft(2, '0')}m';
  }

  Future<void> _showExportInfo() async {
    if (_isLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tunggu data selesai dimuat sebelum export PDF.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final profile = AppStore.instance.profile;

    final pdfData = ReportPdfData(
      employeeName: profile?.fullName ?? 'Karyawan',
      employeeEmail: profile?.email ?? '',
      department: profile?.department,
      position: profile?.position,
      startDate: _rangeStart,
      endDate: _rangeEnd,
      presentDays: _reportData.presentDays,
      workdayTarget: _reportData.workdayTarget,
      missingDays: _reportData.missingDays,
      offDays: _reportData.offDays,
      totalEntries: _reportData.totalEntries,
      totalWorkDuration: _reportData.totalWorkDuration,
      onTimeCount: _reportData.onTimeCount,
      daysWithCheckIn: _reportData.daysWithCheckIn,
      buckets: _reportData.buckets
          .map((b) => ReportBucket(start: b.start, end: b.end, hours: b.hours))
          .toList(),
    );

    final doc = ReportPdfService.generate(pdfData);

    await Printing.layoutPdf(
      onLayout: (_) async => doc.save(),
      name:
          'Presensia_${profile?.fullName ?? 'Laporan'}_${_dateShort(_rangeStart)}-${_dateShort(_rangeEnd)}.pdf',
    );
  }
}

class _ReportRangeData {
  final DateTime startDate;
  final DateTime endDate;
  final int presentDays;
  final int workdayTarget;
  final int missingDays;
  final int offDays;
  final int reminders;
  final int totalEntries;
  final Duration totalWorkDuration;
  final int onTimeCount;
  final int daysWithCheckIn;
  final int totalDays;
  final List<_RangeBucket> buckets;
  final double peakBucketHours;
  final String peakBucketLabel;
  final double presentRatio;
  final double missingRatio;
  final double offDayRatio;
  final double reminderRatio;

  const _ReportRangeData({
    required this.startDate,
    required this.endDate,
    required this.presentDays,
    required this.workdayTarget,
    required this.missingDays,
    required this.offDays,
    required this.reminders,
    required this.totalEntries,
    required this.totalWorkDuration,
    required this.onTimeCount,
    required this.daysWithCheckIn,
    required this.totalDays,
    required this.buckets,
    required this.peakBucketHours,
    required this.peakBucketLabel,
    required this.presentRatio,
    required this.missingRatio,
    required this.offDayRatio,
    required this.reminderRatio,
  });

  factory _ReportRangeData.empty(DateTime startDate, DateTime endDate) {
    final normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final normalizedEnd = DateTime(endDate.year, endDate.month, endDate.day);

    return _ReportRangeData(
      startDate: normalizedStart,
      endDate: normalizedEnd,
      presentDays: 0,
      workdayTarget: 0,
      missingDays: 0,
      offDays: 0,
      reminders: 0,
      totalEntries: 0,
      totalWorkDuration: Duration.zero,
      onTimeCount: 0,
      daysWithCheckIn: 0,
      totalDays: normalizedEnd.difference(normalizedStart).inDays + 1,
      buckets: [
        _RangeBucket(start: normalizedStart, end: normalizedEnd, hours: 0),
      ],
      peakBucketHours: 0,
      peakBucketLabel: '-',
      presentRatio: 0,
      missingRatio: 0,
      offDayRatio: 0,
      reminderRatio: 0,
    );
  }

  String get attendanceRateLabel {
    if (workdayTarget == 0) {
      return '0%';
    }
    return '${((presentDays / workdayTarget) * 100).round()}%';
  }

  String get punctualityLabel {
    if (daysWithCheckIn == 0) {
      return '0%';
    }
    return '${((onTimeCount / daysWithCheckIn) * 100).round()}%';
  }

  String get averageWorkHoursLabel {
    if (presentDays == 0 || totalWorkDuration == Duration.zero) {
      return '0j';
    }
    final avgMinutes = totalWorkDuration.inMinutes / presentDays;
    final hours = avgMinutes ~/ 60;
    final minutes = avgMinutes.round() % 60;
    if (hours == 0) {
      return '${minutes}m';
    }
    return '${hours}j ${minutes.toString().padLeft(2, '0')}m';
  }

  String get peakBucketHoursLabel {
    final wholeHours = peakBucketHours.floor();
    final minutes = ((peakBucketHours - wholeHours) * 60).round();
    if (peakBucketHours == 0) {
      return '0j';
    }
    if (minutes == 0) {
      return '${wholeHours}j';
    }
    return '${wholeHours}j ${minutes.toString().padLeft(2, '0')}m';
  }
}

class _RangeBucket {
  final DateTime start;
  final DateTime end;
  final double hours;

  const _RangeBucket({
    required this.start,
    required this.end,
    required this.hours,
  });

  String get shortLabel {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agt',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return '${start.day} ${months[start.month - 1]}';
  }
}
