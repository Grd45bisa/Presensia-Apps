import 'package:flutter/material.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/models/app_models.dart';
import '../../../shared/services/attendance_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/providers/notification_provider.dart';
import '../../../shared/store/app_store.dart';
import 'camera_face_view.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _store = AppStore.instance;
  final _cameraKey = GlobalKey<CameraFaceViewState>();

  bool _processing = false;

  DateTime get _today =>
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  AttendanceRecord? get _todayRecord => _store.attendanceOf(_today);
  bool get _isCheckedIn => _todayRecord?.checkIn != null;
  bool get _isCheckedOut => _todayRecord?.checkOut != null;

  // ── Face detection callbacks ──────────────────────────────────────────────

  Future<void> _onFaceDetected() async {
    if (_processing || _isCheckedOut) return;
    setState(() => _processing = true);

    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) return;

      if (!_isCheckedIn) {
        // First scan of the day → Check-in
        final record = await AttendanceService.instance.checkIn(
          uid,
          source: AttendanceSource.face,
        );
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        // Reset camera so user can later scan for check-out
        _cameraKey.currentState?.resetToReady();
        _showResult(
          success: true,
          message: 'Check-in berhasil pukul ${_fmtTod(record.checkIn!)}',
        );
      } else {
        // Second scan → confirm check-out
        final confirmed = await _confirmCheckOut();
        if (!confirmed) {
          // User cancelled — reset camera to ready
          _cameraKey.currentState?.resetToReady();
          return;
        }
        final record = await AttendanceService.instance.checkOut(uid);
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        // Mark camera done — no more scanning needed today
        _cameraKey.currentState?.markDone();
        _showResult(
          success: true,
          message: 'Check-out berhasil pukul ${_fmtTod(record.checkOut!)}',
          color: AppColors.error,
        );
      }
    } catch (e) {
      _showResult(success: false, message: 'Gagal menyimpan presensi. Coba lagi.');
      _cameraKey.currentState?.resetToReady();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _onTimeout() {
    // CameraFaceView already shows timeout UI — nothing extra needed here.
  }

  Future<bool> _confirmCheckOut() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Konfirmasi Check-Out',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Wajah terdeteksi. Lanjutkan check-out sekarang?',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Check-Out', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showResult({
    required bool success,
    required String message,
    Color? color,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: color ?? (success ? AppColors.success : AppColors.error),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            Icon(
              success ? Icons.check_circle_rounded : Icons.error_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Button action (manual trigger scan) ───────────────────────────────────

  void _handleButtonTap() {
    if (_isCheckedOut || _processing) return;
    _cameraKey.currentState?.startScan();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                children: [
                  _buildStatusSummary(),
                  const SizedBox(height: 14),
                  Expanded(child: _buildCameraArea()),
                  const SizedBox(height: 14),
                  _buildSupportingInfo(),
                  const SizedBox(height: 14),
                  _buildActionButton(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      toolbarHeight: 64,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Absensi',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _todayLabel(),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
          child: Align(
            alignment: Alignment.center,
            child: _buildStatusBadge(),
          ),
        ),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: AppColors.border),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final (label, color, bg) = _statusStyle();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  (String, Color, Color) _statusStyle() {
    if (_isCheckedOut) return ('Selesai', AppColors.success, AppColors.successLight);
    if (_isCheckedIn) return ('Sudah Check-In', AppColors.warning, AppColors.warningLight);
    return ('Belum Hadir', AppColors.missing, AppColors.missingLight);
  }

  // ── Status summary ────────────────────────────────────────────────────────

  Widget _buildStatusSummary() {
    final record = _todayRecord;
    final cin = record?.checkIn;
    final cout = record?.checkOut;
    final cinText = cin != null ? _fmtTod(cin) : '--:--';
    final coutText = cout != null ? _fmtTod(cout) : '--:--';
    final duration = (cin != null && cout != null) ? _duration(cin, cout) : '--j --m';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _summarySlot(
              icon: Icons.login_rounded,
              iconColor: cin != null ? AppColors.success : AppColors.textSecondary,
              iconBg: cin != null ? AppColors.successLight : AppColors.background,
              label: 'Check-in',
              value: cinText,
              valueColor: cin != null ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
          _verticalDivider(),
          Expanded(
            child: _summarySlot(
              icon: Icons.logout_rounded,
              iconColor: cout != null ? AppColors.error : AppColors.textSecondary,
              iconBg: cout != null ? AppColors.errorLight : AppColors.background,
              label: 'Check-out',
              value: coutText,
              valueColor: cout != null ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
          _verticalDivider(),
          Expanded(
            child: _summarySlot(
              icon: Icons.schedule_rounded,
              iconColor: AppColors.primary,
              iconBg: AppColors.primaryLight,
              label: 'Durasi',
              value: duration,
              valueColor: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summarySlot({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: iconColor),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: valueColor,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  Widget _verticalDivider() => Container(
    width: 1,
    height: 42,
    color: AppColors.border,
    margin: const EdgeInsets.symmetric(horizontal: 4),
  );

  // ── Camera area ───────────────────────────────────────────────────────────

  Widget _buildCameraArea() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.face_retouching_natural_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Verifikasi Wajah',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _cameraSubtitle(),
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (_processing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: CameraFaceView(
              key: _cameraKey,
              active: !_isCheckedOut,
              hint: _cameraHint(),
              onFaceDetected: _onFaceDetected,
              onTimeout: _onTimeout,
            ),
          ),
        ],
      ),
    );
  }

  String _cameraHint() {
    if (_isCheckedOut) return 'Presensi hari ini sudah selesai';
    if (_isCheckedIn) return 'Tap tombol untuk mulai scan check-out';
    return 'Tap tombol untuk mulai scan check-in';
  }

  String _cameraSubtitle() {
    if (_isCheckedOut) return 'Presensi hari ini sudah selesai';
    if (_isCheckedIn) return 'Siap check-out — scan wajah untuk konfirmasi';
    return 'Posisikan wajah di dalam area oval';
  }

  // ── Supporting info ───────────────────────────────────────────────────────

  Widget _buildSupportingInfo() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: _infoItem(
              icon: Icons.verified_user_rounded,
              label: 'Metode',
              value: 'Face Recognition',
            ),
          ),
          _infoDivider(),
          Expanded(
            child: _infoItem(
              icon: Icons.location_on_rounded,
              label: 'Lokasi',
              value: 'Kantor Pusat',
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoItem({required IconData icon, required String label, required String value}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
              const SizedBox(height: 1),
              Text(
                value,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoDivider() => Container(
    width: 1,
    height: 28,
    color: AppColors.border,
    margin: const EdgeInsets.symmetric(horizontal: 8),
  );

  // ── Action button ─────────────────────────────────────────────────────────

  Widget _buildActionButton() {
    final IconData icon;
    final String label;
    final Color bg;
    final VoidCallback? onPressed;

    if (_isCheckedOut) {
      icon = Icons.check_circle_rounded;
      label = 'Presensi Selesai';
      bg = AppColors.success;
      onPressed = null;
    } else if (_isCheckedIn) {
      icon = Icons.logout_rounded;
      label = _processing ? 'Memproses…' : 'Scan Wajah untuk Check-Out';
      bg = AppColors.error;
      onPressed = _processing ? null : _handleButtonTap;
    } else {
      icon = Icons.face_retouching_natural_rounded;
      label = _processing ? 'Memproses…' : 'Scan Wajah untuk Check-In';
      bg = AppColors.primary;
      onPressed = _processing ? null : _handleButtonTap;
    }

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.successLight,
          disabledForegroundColor: AppColors.success,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _duration(TimeOfDay a, TimeOfDay b) {
    var mins = (b.hour * 60 + b.minute) - (a.hour * 60 + a.minute);
    if (mins < 0) mins += 24 * 60;
    if (mins <= 0) return '0j 00m';
    return '${mins ~/ 60}j ${(mins % 60).toString().padLeft(2, '0')}m';
  }

  String _todayLabel() {
    final now = DateTime.now();
    const months = [
      'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember',
    ];
    const days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}';
  }
}

