import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../../../shared/models/app_models.dart';
import '../../../shared/providers/notification_provider.dart';
import '../../../shared/services/attendance_dev_settings.dart';
import '../../../shared/services/attendance_geofence_service.dart';
import '../../../shared/services/attendance_schedule_service.dart';
import '../../../shared/services/attendance_service.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/face/embedding_sync_service.dart';
import '../../../shared/services/face/face_recognition_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';
import '../../enrollment/presentation/enrollment_screen.dart';
import 'camera_face_view.dart';

class AttendanceScreen extends StatefulWidget {
  final bool isActive;
  final VoidCallback? onAttendanceSuccessDismissed;

  const AttendanceScreen({
    super.key,
    this.isActive = true,
    this.onAttendanceSuccessDismissed,
  });

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  static const double _faceMatchThreshold = 0.65;
  static const int _verificationSampleTarget = 5;

  final _store = AppStore.instance;
  final _devSettings = AttendanceDevSettings.instance;
  GlobalKey<CameraFaceViewState> _cameraKey = GlobalKey<CameraFaceViewState>();
  bool _processing = false;
  bool _isEnrolled = false;
  bool _enrollChecked = false;
  bool _checkingFace = false;
  bool _faceMatched = false;
  bool _matchFailed = false;
  double? _lastSimilarity;
  String? _bestTarget;
  int _verificationSamples = 0;
  _StoredMatch? _bestVerificationMatch;
  String? _cachedEmbeddingUid;
  List<List<double>>? _cachedEmbeddings;
  AttendanceScheduleConfig? _scheduleConfig;
  WorkShift? _selectedShift;
  ScheduleValidationResult? _pendingScheduleValidation;
  GeofenceValidationResult? _pendingGeofenceValidation;
  bool _scheduleLoading = true;
  String? _scheduleMessage;
  bool _checkingGeofence = false;
  bool _preparingLocation = false;
  bool _locationReady = false;
  String? _locationMessage;

  DateTime get _today =>
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  AttendanceRecord? get _todayRecord => _store.attendanceOf(_today);
  bool get _isCheckedIn => _todayRecord?.checkIn != null;
  bool get _isCheckedOut => _todayRecord?.checkOut != null;

  @override
  void initState() {
    super.initState();
    _checkEnrollmentStatus();
    _loadScheduleConfig();
    _prepareLocationAccess();
    unawaited(FaceRecognitionService.instance.init());
  }

  Future<void> _prepareLocationAccess() async {
    setState(() {
      _preparingLocation = true;
      _locationMessage = null;
    });

    try {
      await AttendanceGeofenceService.instance.prepareLocationAccess();
      if (!mounted) return;
      setState(() {
        _locationReady = true;
        _locationMessage = 'GPS siap untuk validasi presensi.';
      });
    } on GeofencePermissionException catch (e) {
      if (!mounted) return;
      setState(() {
        _locationReady = false;
        _locationMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _locationReady = false;
        _locationMessage = 'GPS belum siap. Aktifkan lokasi sebelum presensi.';
      });
    } finally {
      if (mounted) setState(() => _preparingLocation = false);
    }
  }

  Future<void> _loadScheduleConfig() async {
    try {
      final config = await AttendanceScheduleService.instance.fetchConfig();
      if (!mounted) return;
      setState(() {
        _scheduleConfig = config;
        _selectedShift = config.shifts.isNotEmpty ? config.shifts.first : null;
        _scheduleLoading = false;
        _scheduleMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scheduleLoading = false;
        _scheduleMessage = 'Gagal memuat aturan jam kerja.';
      });
    }
  }

  Future<void> _checkEnrollmentStatus() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    final embeddings = await _loadStoredEmbeddings(uid, forceRefresh: true);
    if (!mounted) return;
    setState(() {
      _isEnrolled = embeddings != null && embeddings.isNotEmpty;
      _enrollChecked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: Listenable.merge([_store, _devSettings]),
        builder: (context, _) {
          if (!_enrollChecked) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }
          if (!_isEnrolled) return _buildEnrollPrompt();
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
              children: [
                _buildScheduleCard(),
                const SizedBox(height: 14),
                _buildCameraArea(),
                const SizedBox(height: 14),
                _buildFaceStatus(),
                const SizedBox(height: 14),
                _buildActionButton(),
                const SizedBox(height: 14),
                _buildStatusSummary(),
              ],
            ),
          );
        },
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
              Icons.event_available_rounded,
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
                  'Absensi',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
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
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
          child: Align(alignment: Alignment.center, child: _buildStatusBadge()),
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
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 5),
          Text(
            label,
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

  (String, Color, Color) _statusStyle() {
    if (_isCheckedOut) {
      return ('Selesai', AppColors.success, AppColors.successLight);
    }
    if (_isCheckedIn) {
      return ('Sudah Check-In', AppColors.warning, AppColors.warningLight);
    }
    return ('Belum Hadir', AppColors.missing, AppColors.missingLight);
  }

  Widget _buildStatusSummary() {
    final record = _todayRecord;
    final cin = record?.checkIn;
    final cout = record?.checkOut;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: _softShadow(),
      ),
      child: Row(
        children: [
          Expanded(child: _timeSlot('Check-in', cin, AppColors.success)),
          const SizedBox(width: 10),
          Expanded(child: _timeSlot('Check-out', cout, AppColors.error)),
        ],
      ),
    );
  }

  Widget _timeSlot(String label, TimeOfDay? time, Color activeColor) {
    final hasTime = time != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: hasTime
            ? activeColor.withValues(alpha: 0.08)
            : AppColors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasTime
              ? activeColor.withValues(alpha: 0.14)
              : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasTime ? _fmtTod(time) : '--:--',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: hasTime ? activeColor : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnrollPrompt() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.border),
          boxShadow: _softShadow(),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.12),
                ),
              ),
              child: const Icon(
                Icons.face_retouching_off_rounded,
                size: 38,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Wajah Belum Terdaftar',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Daftarkan wajah terlebih dahulu agar presensi bisa diverifikasi.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: _goToEnrollment,
                icon: const Icon(
                  Icons.face_retouching_natural_rounded,
                  size: 20,
                ),
                label: const Text(
                  'Daftarkan Wajah Sekarang',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleCard() {
    final config = _scheduleConfig;
    if (_scheduleLoading) {
      return _scheduleShell(
        icon: Icons.schedule_rounded,
        title: 'Memuat aturan jam kerja...',
        subtitle: 'Mengambil pengaturan dari dashboard admin.',
        color: AppColors.primary,
        child: const LinearProgressIndicator(minHeight: 2),
      );
    }

    if (_scheduleMessage != null) {
      return _scheduleShell(
        icon: Icons.warning_amber_rounded,
        title: 'Aturan jam belum terbaca',
        subtitle: _scheduleMessage!,
        color: AppColors.warning,
        child: TextButton(
          onPressed: _loadScheduleConfig,
          child: const Text('Coba muat ulang'),
        ),
      );
    }

    if (config == null ||
        !config.scheduleEnabled ||
        config.scheduleMode == 'free') {
      return _scheduleShell(
        icon: Icons.all_inclusive_rounded,
        title: 'Jam presensi bebas',
        subtitle: 'Dashboard admin tidak mengaktifkan batas jam kerja.',
        color: AppColors.textSecondary,
      );
    }

    if (config.scheduleMode == 'shift') {
      return _scheduleShell(
        icon: Icons.work_history_rounded,
        title: 'Shift kerja hari ini',
        subtitle: _isCheckedIn
            ? 'Shift terkunci setelah check-in.'
            : 'Pilih shift sebelum mulai presensi.',
        color: AppColors.primary,
        child: DropdownButtonFormField<String>(
          initialValue: _selectedShift?.id,
          isExpanded: true,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
          items: config.shifts
              .map(
                (shift) => DropdownMenuItem(
                  value: shift.id,
                  child: Text(
                    '${shift.name} (${shift.checkInStart}-${shift.checkOutEnd})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _isCheckedIn
              ? null
              : (value) {
                  setState(() {
                    _selectedShift = config.shifts.firstWhere(
                      (shift) => shift.id == value,
                      orElse: () => config.shifts.first,
                    );
                  });
                },
        ),
      );
    }

    return _scheduleShell(
      icon: Icons.access_time_filled_rounded,
      title: 'Jam kantor aktif',
      subtitle:
          'Masuk ${config.officeCheckInStart}-${config.officeCheckInEnd}, telat setelah ${config.officeLateAfter}. Pulang normal mulai ${config.officeCheckOutStart}.',
      color: AppColors.primary,
    );
  }

  Widget _scheduleShell({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    Widget? child,
  }) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: _softShadow(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (child != null) ...[const SizedBox(height: 12), child],
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    final requireBlink = _devSettings.requireBlinkForAttendance;
    return Container(
      height: 430,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
        boxShadow: _softShadow(),
      ),
      padding: const EdgeInsets.all(6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _isCheckedOut
            ? _completedView()
            : CameraFaceView(
                key: _cameraKey,
                active: widget.isActive,
                hint: requireBlink
                    ? 'Kedipkan mata, lalu tatap lurus'
                    : 'Tatap lurus ke kamera',
                liveMode: false,
                enableLiveness: requireBlink,
                onTimeout: () {
                  _showFaceMatchFailed('Waktu verifikasi habis. Coba ulangi.');
                },
                onFaceDetected:
                    ({
                      required fullImage,
                      required inputImage,
                      required nv21Bytes,
                      required rawWidth,
                      required rawHeight,
                      required rotation,
                      required face,
                    }) => _onFaceDetectedForAttendance(
                      fullImage: fullImage,
                      nv21Bytes: nv21Bytes,
                      rawWidth: rawWidth,
                      rawHeight: rawHeight,
                      rotation: rotation,
                      face: face,
                    ),
              ),
      ),
    );
  }

  Widget _completedView() {
    return Container(
      color: AppColors.successLight,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.task_alt_rounded, size: 56, color: AppColors.success),
          SizedBox(height: 12),
          Text(
            'Presensi selesai',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaceStatus() {
    final (icon, label, color, bg) = _faceStatusStyle();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String, Color, Color) _faceStatusStyle() {
    if (_preparingLocation) {
      return (
        Icons.location_searching_rounded,
        'Menyiapkan GPS untuk presensi...',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_locationMessage != null && !_locationReady) {
      return (
        Icons.location_disabled_rounded,
        _locationMessage!,
        AppColors.error,
        AppColors.errorLight,
      );
    }
    if (_checkingGeofence) {
      return (
        Icons.location_searching_rounded,
        'Memeriksa radius kantor...',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_processing) {
      return (
        Icons.hourglass_top_rounded,
        'Menyimpan presensi...',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_faceMatched) {
      return (
        Icons.verified_rounded,
        'Wajah cocok ${((_lastSimilarity ?? 0) * 100).toStringAsFixed(1)}% (${_bestTarget ?? '-'})',
        AppColors.success,
        AppColors.successLight,
      );
    }
    if (_checkingFace) {
      return (
        Icons.manage_search_rounded,
        'Memverifikasi wajah...',
        AppColors.primary,
        AppColors.primaryLight,
      );
    }
    if (_matchFailed) {
      return (
        Icons.face_retouching_off_rounded,
        _lastSimilarity == null
            ? 'Verifikasi wajah gagal. Coba ulangi.'
            : 'Similarity ${(_lastSimilarity! * 100).toStringAsFixed(1)}%, di bawah ${(_faceMatchThreshold * 100).toStringAsFixed(0)}%.',
        AppColors.error,
        AppColors.errorLight,
      );
    }
    return (
      Icons.face_rounded,
      _locationReady
          ? (_devSettings.requireBlinkForAttendance
                ? 'GPS siap. Tekan presensi, kedipkan mata, lalu tatap lurus ke kamera.'
                : 'GPS siap. Tekan presensi, lalu tatap lurus ke kamera.')
          : (_devSettings.requireBlinkForAttendance
                ? 'Tekan presensi, kedipkan mata, lalu tatap lurus ke kamera.'
                : 'Tekan presensi, lalu tatap lurus ke kamera.'),
      AppColors.textSecondary,
      AppColors.background,
    );
  }

  Widget _buildActionButton() {
    final disabled =
        _processing ||
        _checkingGeofence ||
        _preparingLocation ||
        _isCheckedOut ||
        !widget.isActive;
    final label = _isCheckedOut
        ? 'Presensi Selesai'
        : _isCheckedIn
        ? 'Check-Out'
        : 'Check-In';
    final icon = _isCheckedOut
        ? Icons.check_circle_rounded
        : _isCheckedIn
        ? Icons.logout_rounded
        : Icons.login_rounded;
    final color = _isCheckedIn ? AppColors.error : AppColors.primary;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: disabled ? null : _handleButtonTap,
        icon: _processing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon),
        label: Text(
          _processing
              ? 'Menyimpan...'
              : _preparingLocation
              ? 'Menyiapkan GPS...'
              : _checkingGeofence
              ? 'Cek lokasi...'
              : label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.textSecondary.withValues(
            alpha: 0.24,
          ),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  Future<void> _handleButtonTap() async {
    if (_isCheckedOut ||
        _processing ||
        _checkingGeofence ||
        _preparingLocation) {
      return;
    }
    if (_isCheckedIn) {
      final confirmed = await _confirmCheckOut();
      if (!confirmed) return;
    }

    final validation = await _validateScheduleBeforeScan();
    if (validation == null) return;

    final geofenceValidation = await _validateGeofenceBeforeScan();
    if (geofenceValidation == null) return;

    setState(() {
      _pendingScheduleValidation = validation;
      _pendingGeofenceValidation = geofenceValidation;
      _checkingFace = true;
      _faceMatched = false;
      _matchFailed = false;
      _lastSimilarity = null;
      _bestTarget = null;
      _verificationSamples = 0;
      _bestVerificationMatch = null;
    });

    final started = _cameraKey.currentState?.startScan() ?? false;
    if (!started) {
      setState(() => _checkingFace = false);
      _showResult(
        success: false,
        message: 'Kamera belum siap. Coba lagi sebentar.',
      );
    }
  }

  Future<ScheduleValidationResult?> _validateScheduleBeforeScan() async {
    final config = _scheduleConfig;
    if (_scheduleLoading) {
      _showResult(success: false, message: 'Aturan jam kerja masih dimuat.');
      return null;
    }

    if (config?.requiresShift == true &&
        !_isCheckedIn &&
        _selectedShift == null) {
      _showResult(
        success: false,
        message: 'Pilih shift kerja terlebih dahulu.',
      );
      return null;
    }

    try {
      final validation = await AttendanceScheduleService.instance.validate(
        action: _isCheckedIn ? 'check-out' : 'check-in',
        shiftId: _isCheckedIn
            ? (_todayRecord?.selectedShiftId ?? _selectedShift?.id)
            : _selectedShift?.id,
      );

      if (!validation.allowed) {
        _showResult(success: false, message: validation.message);
        return null;
      }

      if (validation.scheduleStatus == 'early_leave') {
        final confirmed = await _confirmEarlyCheckout(validation.message);
        if (!confirmed) return null;
      }

      if (validation.scheduleStatus == 'checkout_late_prompt') {
        final reason = await _askCheckoutReason();
        if (reason == null) return null;
        return ScheduleValidationResult(
          allowed: validation.allowed,
          scheduleMode: validation.scheduleMode,
          scheduleStatus: validation.scheduleStatus,
          lateMinutes: validation.lateMinutes,
          requiresCheckoutReason: validation.requiresCheckoutReason,
          message: reason,
          selectedShiftId: validation.selectedShiftId,
        );
      }

      return validation;
    } catch (e) {
      _showResult(success: false, message: 'Gagal validasi jadwal: $e');
      return null;
    }
  }

  Future<GeofenceValidationResult?> _validateGeofenceBeforeScan() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return null;

    setState(() {
      _checkingGeofence = true;
      _matchFailed = false;
      _faceMatched = false;
      _lastSimilarity = null;
      _bestTarget = null;
    });

    try {
      final validation = await AttendanceGeofenceService.instance.validate(uid);
      if (validation.allowed) return validation;

      _showResult(
        success: false,
        message: _geofenceFailureMessage(validation),
        icon: Icons.location_off_rounded,
      );
      return null;
    } on GeofencePermissionException catch (e) {
      _showResult(
        success: false,
        message: e.message,
        icon: Icons.location_disabled_rounded,
      );
      return null;
    } catch (e) {
      _showResult(
        success: false,
        message: 'Gagal validasi lokasi kantor: $e',
        icon: Icons.location_off_rounded,
      );
      return null;
    } finally {
      if (mounted) setState(() => _checkingGeofence = false);
    }
  }

  String _geofenceFailureMessage(GeofenceValidationResult validation) {
    if (validation.geofenceStatus == 'outside') {
      final distance = validation.distanceMeters;
      final radius = validation.radiusMeters;
      final detail = distance != null && radius != null
          ? ' Jarak kamu ${distance}m dari kantor, radius yang diizinkan ${radius}m.'
          : '';
      return 'Presensi gagal. Silakan lakukan presensi di dalam radius kantor.$detail';
    }

    if (validation.message.isNotEmpty) {
      return validation.message;
    }

    return 'Presensi gagal. Karyawan kantor wajib presensi di dalam radius kantor.';
  }

  Future<bool> _onFaceDetectedForAttendance({
    required img.Image? fullImage,
    required Uint8List? nv21Bytes,
    required int rawWidth,
    required int rawHeight,
    required InputImageRotation rotation,
    required Face face,
  }) async {
    if (_processing || _isCheckedOut) return true;

    try {
      final uid = AuthService.instance.currentUserId;
      if (uid == null) return true;

      final stored = await _loadStoredEmbeddings(uid);
      if (stored == null || stored.isEmpty) {
        if (!mounted) return true;
        setState(() {
          _isEnrolled = false;
          _checkingFace = false;
        });
        return true;
      }

      if (fullImage == null) return false;
      final query = await FaceRecognitionService.instance.extractEmbedding(
        fullImage,
        face,
      );
      if (query == null || query.isEmpty) {
        return false;
      }

      final match = _bestStoredMatch(query, stored);
      _verificationSamples++;
      if (_bestVerificationMatch == null ||
          match.similarity > _bestVerificationMatch!.similarity) {
        _bestVerificationMatch = match;
      }

      final best = _bestVerificationMatch!;
      _lastSimilarity = best.similarity;
      _bestTarget = '${best.label} / frame $_verificationSamples';

      if (match.similarity < _faceMatchThreshold) {
        if (_verificationSamples >= _verificationSampleTarget) {
          _showFaceMatchFailed('Wajah tidak cocok dengan data terdaftar.');
          return true;
        }
        return false;
      }

      if (!mounted) return true;
      setState(() {
        _checkingFace = false;
        _faceMatched = true;
      });
      await Future.delayed(const Duration(milliseconds: 350));
      await _manualCheckInOrOut(
        source: AttendanceSource.face,
        evidenceImage: fullImage,
        faceSimilarity: best.similarity,
      );
      _cameraKey.currentState?.markDone();
      return true;
    } on QualityFilterException {
      return false;
    } catch (e) {
      _showFaceMatchFailed('Presensi wajah gagal. Coba lagi.');
      return true;
    }
  }

  Future<List<List<double>>?> _loadStoredEmbeddings(
    String uid, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _cachedEmbeddingUid == uid &&
        _cachedEmbeddings != null &&
        _cachedEmbeddings!.isNotEmpty) {
      return _cachedEmbeddings;
    }

    final embeddings = await EmbeddingSyncService.instance.getEmbeddings(uid);
    if (embeddings != null && embeddings.isNotEmpty) {
      _cachedEmbeddingUid = uid;
      _cachedEmbeddings = embeddings;
    } else if (forceRefresh || _cachedEmbeddingUid == uid) {
      _cachedEmbeddingUid = null;
      _cachedEmbeddings = null;
    }
    return embeddings;
  }

  _StoredMatch _bestStoredMatch(
    List<double> query,
    List<List<double>> storedEmbeddings,
  ) {
    double bestSimilarity = -1;
    int bestIndex = 0;
    for (int i = 0; i < storedEmbeddings.length; i++) {
      final stored = storedEmbeddings[i];
      if (stored.length != query.length) continue;
      final similarity = FaceRecognitionService.cosineSimilarity(query, stored);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestIndex = i;
      }
    }
    return _StoredMatch(
      similarity: bestSimilarity.clamp(0.0, 1.0),
      label: switch (bestIndex) {
        0 => 'Frontal avg',
        1 => 'Frontal best',
        2 => 'Kiri avg',
        3 => 'Kiri best',
        4 => 'Kanan avg',
        5 => 'Kanan best',
        _ => 'Embedding ${bestIndex + 1}',
      },
    );
  }

  void _showFaceMatchFailed(String message) {
    if (!mounted) return;
    setState(() {
      _checkingFace = false;
      _faceMatched = false;
      _matchFailed = true;
    });
    _showResult(success: false, message: message);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || _processing || _checkingFace) return;
      _cameraKey.currentState?.resetToReady();
    });
  }

  Future<bool> _confirmCheckOut() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Check-out sekarang?'),
        content: const Text(
          'Jam selesai kerja hari ini akan dicatat sebagai waktu check-out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Check-Out'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _confirmEarlyCheckout(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Pulang lebih awal?'),
        content: Text(
          message.isEmpty
              ? 'Check-out ini akan ditandai sebagai pulang duluan.'
              : message,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lanjut Check-Out'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _askCheckoutReason() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Check-out lewat jam normal'),
        content: const Text(
          'Pilih alasan agar laporan admin bisa membedakan lembur atau lupa absen pulang.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'forgot_checkout'),
            child: const Text('Lupa absen pulang'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'overtime'),
            child: const Text('Lembur'),
          ),
        ],
      ),
    );
  }

  Future<void> _manualCheckInOrOut({
    AttendanceSource source = AttendanceSource.manual,
    img.Image? evidenceImage,
    double? faceSimilarity,
  }) async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    setState(() => _processing = true);
    try {
      if (!await _isOnline()) {
        _showResult(
          success: false,
          message: 'Tidak ada koneksi internet.',
          icon: Icons.wifi_off_rounded,
        );
        return;
      }

      if (!_isCheckedIn) {
        final record = await AttendanceService.instance.checkIn(
          uid,
          source: source,
          evidenceImage: evidenceImage,
          faceSimilarity: faceSimilarity,
          faceThreshold: _faceMatchThreshold,
          scheduleValidation: _pendingScheduleValidation,
          geofenceValidation: _pendingGeofenceValidation,
          selectedShiftId: _selectedShift?.id,
        );
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        await _showAttendanceSuccessDialog(
          title: 'Check-in Berhasil',
          message: 'Selamat bekerja. Semoga hari ini lancar dan produktif.',
          timeLabel: 'Check-in pukul ${_fmtTod(record.checkIn!)}',
          icon: Icons.work_history_rounded,
          color: AppColors.success,
        );
      } else {
        final record = await AttendanceService.instance.checkOut(
          uid,
          evidenceImage: evidenceImage,
          faceSimilarity: faceSimilarity,
          faceThreshold: _faceMatchThreshold,
          scheduleValidation: _pendingScheduleValidation,
          geofenceValidation: _pendingGeofenceValidation,
          selectedShiftId: _todayRecord?.selectedShiftId ?? _selectedShift?.id,
          checkoutReason:
              _pendingScheduleValidation?.scheduleStatus ==
                  'checkout_late_prompt'
              ? _pendingScheduleValidation?.message
              : null,
        );
        if (!mounted) return;
        _store.setAttendance(record);
        NotificationProvider.instance.refresh();
        await _showAttendanceSuccessDialog(
          title: 'Check-out Berhasil',
          message: 'Terima kasih untuk kerja keras hari ini. Selamat pulang.',
          timeLabel: 'Check-out pukul ${_fmtTod(record.checkOut!)}',
          icon: Icons.home_rounded,
          color: AppColors.primary,
        );
      }
    } catch (e) {
      if (mounted) _showResult(success: false, message: 'Gagal: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return result.any((r) => r != ConnectivityResult.none);
  }

  Future<void> _goToEnrollment() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const EnrollmentScreen()),
    );
    if (result == true && mounted) {
      setState(() {
        _isEnrolled = true;
        _enrollChecked = true;
        _cachedEmbeddingUid = null;
        _cachedEmbeddings = null;
        _cameraKey = GlobalKey<CameraFaceViewState>();
      });
    }
  }

  void _showResult({
    required bool success,
    required String message,
    Color? color,
    IconData? icon,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor:
            color ?? (success ? AppColors.success : AppColors.error),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            Icon(
              icon ??
                  (success ? Icons.check_circle_rounded : Icons.error_rounded),
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAttendanceSuccessDialog({
    required String title,
    required String message,
    required String timeLabel,
    required IconData icon,
    required Color color,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 0.14)),
              ),
              child: Icon(icon, color: color, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                timeLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Oke'),
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    widget.onAttendanceSuccessDismissed?.call();
  }

  List<BoxShadow> _softShadow() => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.04),
      blurRadius: 12,
      offset: const Offset(0, 6),
    ),
  ];

  String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _todayLabel() {
    final now = DateTime.now();
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
    return '${now.day} ${months[now.month - 1]} ${now.year}';
  }
}

class _StoredMatch {
  const _StoredMatch({required this.similarity, required this.label});

  final double similarity;
  final String label;
}
