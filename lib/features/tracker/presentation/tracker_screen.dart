import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/models/app_models.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/project_service.dart';
import '../../../shared/services/timer_state_service.dart';
import '../../../shared/services/worklog_service.dart';
import '../../../shared/theme/app_colors.dart';

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  static const double _fabBottomOffset = 0;
  static const double _listBottomGap = 128;

  static const List<Color> _projectColorPalette = [
    AppColors.primary,
    AppColors.success,
    AppColors.warning,
    AppColors.error,
    Color(0xFF0EA5E9),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFFDC2626),
  ];

  final _worklogService = WorklogService.instance;
  final _projectService = ProjectService.instance;
  final _authService = AuthService.instance;
  final _timerStateService = TimerStateService.instance;
  final _taskController = TextEditingController();

  Timer? _ticker;
  DateTime? _startTime;
  final _elapsedNotifier = ValueNotifier<Duration>(Duration.zero);

  List<Project> _projects = [];
  List<WorklogEntry> _worklogs = [];

  bool _isLoading = false;
  String? _errorMessage;
  Project? _activeProject;

  bool get _isRunning => _ticker != null;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _elapsedNotifier.dispose();
    _taskController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final userId = _authService.currentUserId;
    if (userId == null) {
      setState(() {
        _errorMessage = 'User belum login.';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 30));
      final results = await Future.wait([
        _projectService.fetchProjects(userId),
        _worklogService.fetchWorklogsInRange(userId, from, now),
        _timerStateService.fetchActiveTimer(userId),
      ]);

      if (!mounted) return;

      final projects = results[0] as List<Project>;
      final worklogs = results[1] as List<WorklogEntry>;
      final savedStart = results[2] as DateTime?;

      setState(() {
        _projects = projects;
        _worklogs = worklogs;
        _activeProject = _resolveProjectSelection(
          current: _activeProject,
          projects: projects,
        );
        _isLoading = false;
      });

      // Restore running timer if it was persisted (e.g. after force-close)
      if (savedStart != null && !_isRunning) {
        setState(() {
          _startTime = savedStart.toLocal();
          _setElapsed(DateTime.now().difference(_startTime!));
        });
        _resumeTicker();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Gagal memuat data tracker.';
        _isLoading = false;
      });
    }
  }

  Project? _resolveProjectSelection({
    required Project? current,
    required List<Project> projects,
  }) {
    if (projects.isEmpty) return null;
    if (current == null) return projects.first;

    for (final project in projects) {
      if (project.id == current.id) return project;
    }
    return projects.first;
  }

  void _startTimer() {
    if (_isRunning) return;

    final start = DateTime.now();
    setState(() {
      _startTime = start;
      _setElapsed(Duration.zero);
    });

    final userId = _authService.currentUserId;
    if (userId != null) {
      _timerStateService.saveActiveTimer(userId, start);
    }

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _startTime == null) return;
      _setElapsed(DateTime.now().difference(_startTime!));
    });
  }

  Future<void> _stopTimer() async {
    if (_startTime == null) return;

    _ticker?.cancel();
    _ticker = null;

    final start = _startTime!;
    final end = DateTime.now();

    setState(() {});
    _showSaveTimerSheet(start, end);
  }

  Future<void> _showSaveTimerSheet(DateTime start, DateTime end) async {
    final taskController = TextEditingController(
      text: _taskController.text.trim(),
    );
    Project? selectedProject =
        _activeProject ?? (_projects.isNotEmpty ? _projects.first : null);
    var saved = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            final duration = end.difference(start);
            final bottomSafePadding = _sheetBottomPadding(sheetContext);

            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  top: 12,
                  left: 20,
                  right: 20,
                  bottom: bottomSafePadding,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.successLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.stop_circle_rounded,
                              color: AppColors.success,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Simpan Entry',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_formatHHMM(start)} - ${_formatHHMM(end)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _sheetLabel('Nama tugas'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: taskController,
                        autofocus: taskController.text.isEmpty,
                        decoration: _sheetInput('Mis. Review dokumen'),
                      ),
                      const SizedBox(height: 14),
                      _sheetLabel('Project'),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final picked = await _showProjectSelectionSheet(
                            initial: selectedProject,
                          );
                          if (picked != null) {
                            setSheet(() => selectedProject = picked);
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color:
                                      selectedProject?.color ??
                                      AppColors.textSecondary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  selectedProject?.name ?? 'Pilih project',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: AppColors.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.textSecondary,
                                side: const BorderSide(color: AppColors.border),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Lanjutkan Timer',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () async {
                                if (taskController.text.trim().isEmpty) {
                                  ScaffoldMessenger.of(
                                    sheetContext,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text('Isi nama tugasnya'),
                                    ),
                                  );
                                  return;
                                }
                                if (selectedProject == null) {
                                  ScaffoldMessenger.of(
                                    sheetContext,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text('Pilih project dulu'),
                                    ),
                                  );
                                  return;
                                }

                                final userId = _authService.currentUserId;
                                if (userId == null) return;

                                final entry = WorklogEntry(
                                  id: const Uuid().v4(),
                                  date: DateTime(
                                    start.year,
                                    start.month,
                                    start.day,
                                  ),
                                  taskName: taskController.text.trim(),
                                  projectName: selectedProject!.name,
                                  projectColor: selectedProject!.color,
                                  startTime: TimeOfDay.fromDateTime(start),
                                  endTime: TimeOfDay.fromDateTime(end),
                                  duration: _formatDuration(duration),
                                );

                                try {
                                  final savedEntry = await _worklogService
                                      .createWorklog(entry, userId);
                                  await _timerStateService.clearActiveTimer(
                                    userId,
                                  );
                                  if (!mounted || !sheetContext.mounted) return;
                                  saved = true;
                                  setState(() {
                                    _startTime = null;
                                    _setElapsed(Duration.zero);
                                    _taskController.clear();
                                    _activeProject = selectedProject;
                                    _worklogs = [savedEntry, ..._worklogs];
                                  });
                                  Navigator.pop(sheetContext);
                                  _showSnackBar('Aktivitas berhasil disimpan.');
                                } catch (_) {
                                  if (!mounted || !sheetContext.mounted) return;
                                  ScaffoldMessenger.of(
                                    sheetContext,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Gagal menyimpan aktivitas. Coba lagi.',
                                      ),
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                'Simpan Entry',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    // Capture text before disposing
    final capturedText = taskController.text.trim();
    taskController.dispose();

    if (!mounted) return;
    if (!saved) {
      setState(() {
        _taskController.text = capturedText;
        _activeProject = selectedProject;
        _startTime = start;
        _setElapsed(DateTime.now().difference(start));
      });
      _resumeTicker();
    }
  }

  void _resumeTicker() {
    _ticker?.cancel();
    if (_startTime == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _startTime == null) return;
      _setElapsed(DateTime.now().difference(_startTime!));
    });
  }

  Future<void> _deleteEntry(WorklogEntry entry) async {
    final userId = _authService.currentUserId;
    if (userId == null) return;

    try {
      await _worklogService.deleteWorklog(entry.id, userId);
      await _loadData();
      if (!mounted) return;
      _showSnackBar('Aktivitas dihapus.');
    } catch (_) {
      if (!mounted) return;
      _showSnackBar('Gagal menghapus aktivitas.');
    }
  }

  void _continueEntry(WorklogEntry entry) {
    if (_isRunning) {
      _showSnackBar('Hentikan timer yang sedang berjalan dulu.');
      return;
    }

    setState(() {
      _taskController.text = entry.taskName;
      _activeProject =
          _findProjectByName(entry.projectName) ??
          Project(
            id: 'project-${entry.projectName}',
            name: entry.projectName,
            color: entry.projectColor,
          );
    });
    _startTimer();
  }

  Project? _findProjectByName(String name) {
    for (final project in _projects) {
      if (project.name == name) return project;
    }
    return null;
  }

  void _setElapsed(Duration value) {
    _elapsedNotifier.value = value;
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByDate(_worklogs);
    final sortedDates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final media = MediaQuery.of(context);
    final bottomInset = media.padding.bottom > 0
        ? media.padding.bottom
        : media.viewPadding.bottom;
    final fabBottomPadding = bottomInset + _fabBottomOffset;
    final contentBottomPadding = fabBottomPadding + _listBottomGap;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                )
              : _errorMessage != null
              ? _buildErrorState()
              : Column(
                  children: [
                    _buildTimerPanel(),
                    _buildTodaySummary(),
                    Expanded(
                      child: _worklogs.isEmpty
                          ? _buildEmptyState(contentBottomPadding)
                          : ListView.builder(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                14,
                                16,
                                contentBottomPadding,
                              ),
                              itemCount: sortedDates.length,
                              itemBuilder: (context, index) {
                                final date = sortedDates[index];
                                final items = [...grouped[date]!]
                                  ..sort((a, b) {
                                    final aStart = _timeToMinutes(a.startTime);
                                    final bStart = _timeToMinutes(b.startTime);
                                    return bStart.compareTo(aStart);
                                  });
                                return _buildDateGroup(date, items);
                              },
                            ),
                    ),
                  ],
                ),
          Positioned(
            right: 16,
            bottom: fabBottomPadding,
            child: _buildAddButton(),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      toolbarHeight: 64,
      title: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.timer_rounded,
              color: AppColors.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tracker',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isRunning
                      ? 'Timer sedang berjalan'
                      : 'Catat aktivitas kerja',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
          child: Align(
            alignment: Alignment.center,
            child: _buildRunningBadge(),
          ),
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: AppColors.border),
      ),
    );
  }

  Widget _buildRunningBadge() {
    final color = _isRunning ? AppColors.success : AppColors.textSecondary;
    final bg = _isRunning ? AppColors.successLight : AppColors.background;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isRunning
              ? AppColors.success.withValues(alpha: 0.12)
              : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 5),
          Text(
            _isRunning ? 'Aktif' : 'Siap',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddButton() {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A0F172A),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: FloatingActionButton.extended(
        onPressed: _showManualEntrySheet,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        extendedPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 0,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: const Icon(Icons.edit_calendar_rounded, size: 20),
        label: const Text(
          'Tambah',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.errorLight,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.2),
                ),
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: _loadData,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Coba lagi'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimerPanel() {
    final accentColor = _activeProject?.color ?? AppColors.primary;

    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.border),
          boxShadow: _softShadow(),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      _isRunning
                          ? Icons.play_circle_fill_rounded
                          : Icons.edit_note_rounded,
                      color: accentColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _taskController,
                      enabled: !_isRunning,
                      decoration: const InputDecoration(
                        hintText: 'Apa yang kamu kerjakan?',
                        hintStyle: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _isRunning ? null : _showProjectPicker,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _activeProject?.name ?? 'Pilih project',
                            style: TextStyle(
                              fontSize: 11,
                              color: accentColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!_isRunning) ...[
                            const SizedBox(width: 2),
                            Icon(
                              Icons.arrow_drop_down_rounded,
                              size: 16,
                              color: accentColor,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _isRunning ? _changeStartTime : null,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              ValueListenableBuilder<Duration>(
                                valueListenable: _elapsedNotifier,
                                builder: (context, elapsed, _) {
                                  return Text(
                                    _formatDurationClock(elapsed),
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900,
                                      color: _isRunning
                                          ? AppColors.primary
                                          : AppColors.textSecondary,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              if (_isRunning) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.edit_rounded,
                                  size: 14,
                                  color: AppColors.primary,
                                ),
                              ],
                            ],
                          ),
                          if (_isRunning && _startTime != null)
                            Text(
                              'Mulai: ${_formatHHMM(_startTime!)} · tap untuk ubah',
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            )
                          else
                            const Text(
                              'Isi nama tugas lalu tekan MULAI',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 42,
                    child: ElevatedButton(
                      onPressed: _isRunning ? _stopTimer : _startTimer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isRunning
                            ? AppColors.error
                            : AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isRunning
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            size: 20,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isRunning ? 'BERHENTI' : 'MULAI',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodaySummary() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayEntries = _worklogs.where((entry) {
      final date = DateTime(entry.date.year, entry.date.month, entry.date.day);
      return date == today;
    }).toList();
    final total = todayEntries.fold<Duration>(
      Duration.zero,
      (sum, entry) => sum + _entryDuration(entry),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _summaryMetric(
              icon: Icons.task_alt_rounded,
              label: 'Aktivitas',
              value: '${todayEntries.length}',
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _summaryMetric(
              icon: Icons.schedule_rounded,
              label: 'Total hari ini',
              value: _formatDuration(total),
              color: AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryMetric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateGroup(DateTime date, List<WorklogEntry> items) {
    final total = items.fold<Duration>(Duration.zero, (sum, entry) {
      return sum + _entryDuration(entry);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _dateLabel(date),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    '${items.length} aktivitas tercatat',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
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
                  _formatDuration(total),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...items.map(_buildEntryCard),
      ],
    );
  }

  Widget _buildEntryCard(WorklogEntry entry) {
    final timeLabel =
        '${_formatTimeOfDay(entry.startTime)} - ${_formatTimeOfDay(entry.endTime)}';
    final duration = _entryDuration(entry);
    final durationLabel = duration > Duration.zero
        ? _formatDuration(duration)
        : entry.duration;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.taskName,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: entry.projectColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        entry.projectName,
                        style: TextStyle(
                          fontSize: 11,
                          color: entry.projectColor,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Text(
                      '  ·  ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      timeLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.10),
                  ),
                ),
                child: Text(
                  durationLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_horiz_rounded,
              size: 20,
              color: AppColors.textSecondary,
            ),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            onSelected: (value) {
              if (value == 'continue') _continueEntry(entry);
              if (value == 'edit') _showManualEntrySheet(editing: entry);
              if (value == 'delete') _confirmDelete(entry);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'continue',
                child: Row(
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                    SizedBox(width: 10),
                    Text('Lanjutkan', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_rounded,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: 10),
                    Text('Edit', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_rounded,
                      size: 16,
                      color: AppColors.error,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Hapus',
                      style: TextStyle(fontSize: 13, color: AppColors.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(double bottomPadding) {
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, bottomPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(
                Icons.timer_outlined,
                size: 36,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Belum ada catatan waktu',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Mulai timer di atas atau tekan tombol Manual untuk menambahkan entry pertama.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showProjectPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const Text(
                  'Pilih Project',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.5,
                  ),
                  child: _projects.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'Belum ada project. Tambah project baru dulu.',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          child: Column(
                            children: _projects.map((project) {
                              return InkWell(
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  setState(() => _activeProject = project);
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: project.color,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          project.name,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: AppColors.textPrimary,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      if (_activeProject?.id == project.id)
                                        const Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                          color: AppColors.primary,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final created = await _showCreateProjectSheet();
                    if (!mounted || !sheetContext.mounted || created == null) {
                      return;
                    }
                    setSheet(() {});
                    Navigator.pop(sheetContext);
                    setState(() => _activeProject = created);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                    child: Row(
                      children: [
                        _AddProjectIcon(),
                        SizedBox(width: 10),
                        Text(
                          'Tambah Project Baru',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<Project?> _showCreateProjectSheet() {
    final nameController = TextEditingController();
    Color selectedColor = _projectColorPalette.first;

    return showModalBottomSheet<Project>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) => Padding(
            padding: EdgeInsets.only(
              top: 12,
              left: 20,
              right: 20,
              bottom: _sheetBottomPadding(sheetContext),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.folder_rounded,
                        color: AppColors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Project Baru',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _sheetLabel('Nama project'),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: _sheetInput('Mis. Website Client A'),
                  onChanged: (_) => setSheet(() {}),
                ),
                const SizedBox(height: 18),
                _sheetLabel('Warna'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _projectColorPalette.map((color) {
                    final isSelected =
                        color.toARGB32() == selectedColor.toARGB32();
                    return GestureDetector(
                      onTap: () => setSheet(() => selectedColor = color),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? AppColors.textPrimary : color,
                            width: isSelected ? 3 : 0,
                          ),
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 20,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'Preview: ',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: selectedColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: selectedColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              nameController.text.trim().isEmpty
                                  ? 'Nama project'
                                  : nameController.text.trim(),
                              style: TextStyle(
                                fontSize: 11,
                                color: selectedColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          const SnackBar(
                            content: Text('Isi nama project dulu'),
                          ),
                        );
                        return;
                      }

                      final userId = _authService.currentUserId;
                      if (userId == null) return;

                      try {
                        final project = await _projectService.createProject(
                          Project(
                            id: const Uuid().v4(),
                            name: name,
                            color: selectedColor,
                          ),
                          userId,
                        );
                        await _loadData();
                        if (!mounted || !sheetContext.mounted) return;
                        Navigator.pop(sheetContext, project);
                      } catch (_) {
                        if (!mounted || !sheetContext.mounted) return;
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Gagal menyimpan project. Coba lagi.',
                            ),
                          ),
                        );
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
                    child: const Text(
                      'Simpan Project',
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
      },
    );
  }

  void _showManualEntrySheet({WorklogEntry? editing}) {
    final taskController = TextEditingController(text: editing?.taskName ?? '');
    Project? selectedProject = editing != null
        ? _findProjectByName(editing.projectName)
        : (_projects.isNotEmpty ? _projects.first : _activeProject);
    DateTime date = editing?.date ?? DateTime.now();
    TimeOfDay start = editing?.startTime ?? const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay end = editing?.endTime ?? TimeOfDay.fromDateTime(DateTime.now());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            Duration calcDuration() {
              final startDateTime = DateTime(
                date.year,
                date.month,
                date.day,
                start.hour,
                start.minute,
              );
              var endDateTime = DateTime(
                date.year,
                date.month,
                date.day,
                end.hour,
                end.minute,
              );
              if (endDateTime.isBefore(startDateTime)) {
                endDateTime = endDateTime.add(const Duration(days: 1));
              }
              return endDateTime.difference(startDateTime);
            }

            final duration = calcDuration();

            return Padding(
              padding: EdgeInsets.only(
                top: 12,
                left: 20,
                right: 20,
                bottom: _sheetBottomPadding(sheetContext),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                          editing == null ? 'Tambah' : 'Edit Entry',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _sheetLabel('Nama tugas'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: taskController,
                      decoration: _sheetInput('Mis. Review dokumen'),
                    ),
                    const SizedBox(height: 14),
                    _sheetLabel('Project'),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () async {
                        final picked = await _showProjectSelectionSheet(
                          initial: selectedProject,
                        );
                        if (picked != null) {
                          setSheet(() => selectedProject = picked);
                        }
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color:
                                    selectedProject?.color ??
                                    AppColors.textSecondary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                selectedProject?.name ?? 'Pilih project',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _sheetLabel('Tanggal'),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: sheetContext,
                          initialDate: date,
                          firstDate: DateTime.now().subtract(
                            const Duration(days: 365),
                          ),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (picked != null) {
                          setSheet(() => date = picked);
                        }
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_rounded,
                              size: 16,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _dateFull(date),
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
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
                              _sheetLabel('Jam Mulai'),
                              const SizedBox(height: 6),
                              _timeButton(
                                sheetContext,
                                start,
                                (picked) => setSheet(() => start = picked),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _sheetLabel('Jam Selesai'),
                              const SizedBox(height: 6),
                              _timeButton(
                                sheetContext,
                                end,
                                (picked) => setSheet(() => end = picked),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Total durasi:',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: () async {
                          if (taskController.text.trim().isEmpty) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('Isi nama tugasnya'),
                              ),
                            );
                            return;
                          }
                          if (selectedProject == null) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('Pilih project dulu'),
                              ),
                            );
                            return;
                          }
                          if (duration <= Duration.zero) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('Durasi tidak boleh kosong'),
                              ),
                            );
                            return;
                          }

                          final userId = _authService.currentUserId;
                          if (userId == null) return;

                          final startDateTime = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            start.hour,
                            start.minute,
                          );
                          var endDateTime = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            end.hour,
                            end.minute,
                          );
                          if (endDateTime.isBefore(startDateTime)) {
                            endDateTime = endDateTime.add(
                              const Duration(days: 1),
                            );
                          }

                          final entry = WorklogEntry(
                            id: editing?.id ?? const Uuid().v4(),
                            date: DateTime(date.year, date.month, date.day),
                            taskName: taskController.text.trim(),
                            projectName: selectedProject!.name,
                            projectColor: selectedProject!.color,
                            startTime: TimeOfDay.fromDateTime(startDateTime),
                            endTime: TimeOfDay.fromDateTime(endDateTime),
                            duration: _formatDuration(duration),
                          );

                          try {
                            if (editing == null) {
                              await _worklogService.createWorklog(
                                entry,
                                userId,
                              );
                            } else {
                              await _worklogService.updateWorklog(
                                entry,
                                userId,
                              );
                            }
                            await _loadData();
                            if (!mounted || !sheetContext.mounted) return;
                            Navigator.pop(sheetContext);
                          } catch (_) {
                            if (!mounted || !sheetContext.mounted) return;
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('Gagal menyimpan. Coba lagi.'),
                              ),
                            );
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
                          editing == null ? 'Simpan Entry' : 'Perbarui Entry',
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
        );
      },
    );
  }

  Future<Project?> _showProjectSelectionSheet({Project? initial}) {
    return showModalBottomSheet<Project>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const Text(
                  'Pilih Project',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.45,
                  ),
                  child: _projects.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Belum ada project. Tambah project baru dulu.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : SingleChildScrollView(
                          child: Column(
                            children: _projects.map((project) {
                              final isSelected = initial?.id == project.id;
                              return InkWell(
                                onTap: () =>
                                    Navigator.pop(sheetContext, project),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: project.color,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          project.name,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: AppColors.textPrimary,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      if (isSelected)
                                        const Icon(
                                          Icons.check_rounded,
                                          size: 18,
                                          color: AppColors.primary,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () async {
                    final created = await _showCreateProjectSheet();
                    if (!mounted || !sheetContext.mounted || created == null) {
                      return;
                    }
                    setSheet(() {});
                    Navigator.pop(sheetContext, created);
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                    child: Row(
                      children: [
                        _AddProjectIcon(),
                        SizedBox(width: 10),
                        Text(
                          'Tambah Project Baru',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeButton(
    BuildContext context,
    TimeOfDay value,
    ValueChanged<TimeOfDay> onPick,
  ) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: value,
          builder: (pickerContext, child) => MediaQuery(
            data: MediaQuery.of(
              pickerContext,
            ).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        );
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.access_time_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              _formatTimeOfDay(value),
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeStartTime() async {
    if (!_isRunning || _startTime == null) return;

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startTime!),
      helpText: 'Ubah jam mulai',
      builder: (pickerContext, child) => MediaQuery(
        data: MediaQuery.of(
          pickerContext,
        ).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;

    final now = DateTime.now();
    var newStart = DateTime(
      now.year,
      now.month,
      now.day,
      picked.hour,
      picked.minute,
    );
    if (newStart.isAfter(now)) {
      newStart = newStart.subtract(const Duration(days: 1));
    }

    setState(() {
      _startTime = newStart;
      _setElapsed(DateTime.now().difference(newStart));
    });
  }

  void _confirmDelete(WorklogEntry entry) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Hapus entry?',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          '"${entry.taskName}" akan dihapus permanen.',
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Batal',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _deleteEntry(entry);
            },
            child: const Text(
              'Hapus',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheetLabel(String text) => Text(
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

  InputDecoration _sheetInput(String hint) => InputDecoration(
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

  List<BoxShadow> _softShadow() => [
    BoxShadow(
      color: AppColors.primaryDark.withValues(alpha: 0.045),
      blurRadius: 16,
      offset: const Offset(0, 8),
    ),
  ];

  Map<DateTime, List<WorklogEntry>> _groupByDate(List<WorklogEntry> entries) {
    final grouped = <DateTime, List<WorklogEntry>>{};
    for (final entry in entries) {
      final date = DateTime(entry.date.year, entry.date.month, entry.date.day);
      grouped.putIfAbsent(date, () => []).add(entry);
    }
    return grouped;
  }

  Duration _entryDuration(WorklogEntry entry) {
    if (entry.startTime == null || entry.endTime == null) return Duration.zero;
    var minutes =
        _timeToMinutes(entry.endTime) - _timeToMinutes(entry.startTime);
    if (minutes < 0) minutes += 24 * 60;
    return Duration(minutes: minutes);
  }

  int _timeToMinutes(TimeOfDay? time) {
    if (time == null) return 0;
    return time.hour * 60 + time.minute;
  }

  String _formatDurationClock(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours == 0) return '${minutes}m';
    return '${hours}j ${minutes.toString().padLeft(2, '0')}m';
  }

  String _formatHHMM(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  String _formatTimeOfDay(TimeOfDay? value) {
    if (value == null) return '-';
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  String _dateLabel(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(value).inDays;
    if (diff == 0) return 'Hari Ini';
    if (diff == 1) return 'Kemarin';
    const days = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
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
    return '${days[value.weekday - 1]}, ${value.day} ${months[value.month - 1]}';
  }

  String _dateFull(DateTime value) {
    const days = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
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
    return '${days[value.weekday - 1]}, ${value.day} ${months[value.month - 1]} ${value.year}';
  }
}

class _AddProjectIcon extends StatelessWidget {
  const _AddProjectIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
    );
  }
}
