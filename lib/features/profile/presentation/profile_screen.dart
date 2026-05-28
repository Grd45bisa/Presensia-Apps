import 'package:flutter/material.dart';
import '../../../shared/models/app_models.dart';
import '../../../shared/services/attendance_dev_settings.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/face/embedding_sync_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';
import '../../enrollment/presentation/enrollment_screen.dart';
import 'face_ai_lab_screen.dart';
import '../controller/profile_controller.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _controller = ProfileController();
  final _devSettings = AttendanceDevSettings.instance;
  bool _isEnrolled = false;
  bool _enrollChecked = false;

  @override
  void initState() {
    super.initState();
    _checkEnrollment();
  }

  Future<void> _checkEnrollment() async {
    final uid = AuthService.instance.currentUserId;
    if (uid == null) return;
    final enrolled = await EmbeddingSyncService.instance.isEnrolledOnCloud(uid);
    if (!mounted) return;
    setState(() {
      _isEnrolled = enrolled;
      _enrollChecked = true;
    });
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
      });
    }
  }

  Future<void> _goToFaceAiLab() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FaceAiLabScreen()),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppStore.instance,
        _controller,
        _devSettings,
      ]),
      builder: (context, _) {
        final profile = AppStore.instance.profile;
        final bottomPadding = _screenBottomPadding(context);
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: _buildAppBar(context),
          body: profile == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding),
                  children: [
                    _buildHeader(profile),
                    const SizedBox(height: 18),
                    _sectionLabel('Info Akun'),
                    const SizedBox(height: 8),
                    _buildInfoCard(profile),
                    const SizedBox(height: 18),
                    _sectionLabel('Biometrik Wajah'),
                    const SizedBox(height: 8),
                    _buildBiometricCard(),
                    const SizedBox(height: 18),
                    _sectionLabel('Pengaturan'),
                    const SizedBox(height: 8),
                    _buildSettingsCard(profile),
                    const SizedBox(height: 28),
                    _buildLogoutButton(context),
                  ],
                ),
        );
      },
    );
  }

  // ─── APP BAR ─────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: const Icon(
          Icons.arrow_back_rounded,
          color: AppColors.textPrimary,
        ),
        onPressed: () => Navigator.pop(context),
      ),
      title: const Text(
        'Profil',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: AppColors.border),
      ),
    );
  }

  // ─── HEADER ──────────────────────────────────────────────────────────────

  Widget _buildHeader(EmployeeProfile profile) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDark.withValues(alpha: 0.06),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.18),
                        width: 1.5,
                      ),
                    ),
                    child: profile.avatarUrl != null
                        ? ClipOval(
                            child: Image.network(
                              profile.avatarUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (ctx, err, st) => Center(
                                child: _initialsText(profile.initials),
                              ),
                            ),
                          )
                        : Center(child: _initialsText(profile.initials)),
                  ),
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AppColors.successLight,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: AppColors.success,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.fullName,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 7,
                      runSpacing: 5,
                      children: [
                        _statusPill(
                          'Aktif',
                          AppColors.successLight,
                          AppColors.success,
                        ),
                        if (profile.position?.trim().isNotEmpty == true)
                          _statusPill(
                            profile.position!,
                            AppColors.primaryLight,
                            AppColors.primary,
                          ),
                      ],
                    ),
                    if (profile.department?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 6),
                      Text(
                        profile.department!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _roundIconButton(
                icon: Icons.edit_outlined,
                tooltip: 'Edit Profil',
                onPressed: () => _showEditSheet(context, profile),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.mail_outline_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    profile.email,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _initialsText(String initials) => Text(
    initials,
    style: const TextStyle(
      fontSize: 28,
      color: AppColors.primary,
      fontWeight: FontWeight.bold,
    ),
  );

  // ─── INFO CARD ───────────────────────────────────────────────────────────

  Widget _buildInfoCard(EmployeeProfile profile) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _infoRow(
            icon: Icons.badge_outlined,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'ID Karyawan',
            value: profile.id.substring(0, 8).toUpperCase(),
          ),
          _divider(),
          _infoRow(
            icon: Icons.email_outlined,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Email',
            value: profile.email,
          ),
          _divider(),
          _infoRow(
            icon: Icons.phone_outlined,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Telepon',
            value: profile.phoneNumber?.isNotEmpty == true
                ? profile.phoneNumber!
                : '-',
          ),
          _divider(),
          _infoRow(
            icon: Icons.group_outlined,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Departemen',
            value: profile.department ?? '-',
          ),
          _divider(),
          _infoRow(
            icon: Icons.work_outline_rounded,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Jabatan',
            value: profile.position ?? '-',
          ),
        ],
      ),
    );
  }

  Widget _infoRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── BIOMETRIC CARD ──────────────────────────────────────────────────────

  Widget _buildBiometricCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _enrollChecked
                        ? (_isEnrolled
                              ? AppColors.successLight
                              : AppColors.warningLight)
                        : AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _isEnrolled
                        ? Icons.verified_user_rounded
                        : Icons.face_retouching_off_rounded,
                    size: 16,
                    color: _enrollChecked
                        ? (_isEnrolled ? AppColors.success : AppColors.warning)
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Data Wajah',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !_enrollChecked
                            ? 'Mengecek status...'
                            : _isEnrolled
                            ? 'Wajah sudah terdaftar'
                            : 'Belum ada data wajah',
                        style: TextStyle(
                          fontSize: 12,
                          color: _enrollChecked && _isEnrolled
                              ? AppColors.success
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_enrollChecked)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: AppColors.border,
          ),
          InkWell(
            onTap: _goToEnrollment,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
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
                  const SizedBox(width: 12),
                  Text(
                    _isEnrolled
                        ? 'Daftarkan Ulang Wajah'
                        : 'Daftarkan Wajah Sekarang',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primary,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          const Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: AppColors.border,
          ),
          InkWell(
            onTap: _goToFaceAiLab,
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.warningLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.science_rounded,
                      size: 16,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Face AI Lab',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── SETTINGS CARD ───────────────────────────────────────────────────────

  Widget _buildSettingsCard(EmployeeProfile profile) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _settingRow(
            icon: Icons.notifications_outlined,
            iconColor: AppColors.warning,
            iconBg: AppColors.warningLight,
            label: 'Notifikasi',
            subtitle: profile.notificationsEnabled
                ? 'Reminder dan status harian aktif'
                : 'Reminder sedang dimatikan',
            trailing: Switch(
              value: profile.notificationsEnabled,
              onChanged: (val) => _controller.toggleNotifications(enabled: val),
              activeThumbColor: AppColors.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          _divider(),
          _settingRow(
            icon: Icons.visibility_rounded,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Liveness blink',
            subtitle: 'Diatur oleh admin dari dashboard',
            trailing: Switch(
              value: _devSettings.requireBlinkForAttendance,
              onChanged: null,
              activeThumbColor: AppColors.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          _divider(),
          InkWell(
            onTap: () => _showChangePasswordSheet(context),
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(14),
            ),
            child: _settingRow(
              icon: Icons.lock_outline_rounded,
              iconColor: AppColors.primary,
              iconBg: AppColors.primaryLight,
              label: 'Ubah Password',
              subtitle: 'Perbarui keamanan akun',
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ),
          ),
          _divider(),
          _settingRow(
            icon: Icons.language_rounded,
            iconColor: AppColors.primary,
            iconBg: AppColors.primaryLight,
            label: 'Bahasa',
            subtitle: 'Tampilan aplikasi',
            trailing: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Indonesia',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
          _divider(),
          _settingRow(
            icon: Icons.info_outline_rounded,
            iconColor: AppColors.textSecondary,
            iconBg: AppColors.background,
            label: 'Versi Aplikasi',
            subtitle: 'Presensia mobile',
            trailing: const Text(
              'v1.0.0',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String label,
    String? subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }

  Widget _divider() => const Divider(
    height: 1,
    indent: 16,
    endIndent: 16,
    color: AppColors.border,
  );

  Widget _sectionLabel(String title) => Text(
    title,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: AppColors.textSecondary,
      letterSpacing: 0,
    ),
  );

  Widget _statusPill(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: fg),
      ),
    );
  }

  Widget _roundIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: AppColors.primary),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.primaryLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.primary.withValues(alpha: 0.12)),
        ),
      ),
    );
  }

  double _screenBottomPadding(BuildContext context) {
    final media = MediaQuery.of(context);
    final systemBottom = media.padding.bottom > 0
        ? media.padding.bottom
        : media.viewPadding.bottom;
    return 40 + systemBottom;
  }

  // ─── LOGOUT ──────────────────────────────────────────────────────────────

  Widget _buildLogoutButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: OutlinedButton.icon(
        onPressed: () => _showLogoutDialog(context),
        icon: const Icon(
          Icons.logout_rounded,
          color: AppColors.error,
          size: 18,
        ),
        label: const Text(
          'Keluar dari Akun',
          style: TextStyle(
            color: AppColors.error,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.errorLight,
          side: const BorderSide(color: AppColors.error, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Keluar dari Akun?',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: AppColors.textPrimary,
          ),
        ),
        content: const Text(
          'Kamu perlu login kembali untuk mengakses aplikasi.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Batal',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _controller.signOut();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
  }

  // ─── EDIT PROFILE BOTTOM SHEET ────────────────────────────────────────────

  void _showEditSheet(BuildContext context, EmployeeProfile profile) {
    final nameCtrl = TextEditingController(text: profile.fullName);
    final deptCtrl = TextEditingController(text: profile.department ?? '');
    final posCtrl = TextEditingController(text: profile.position ?? '');
    final phoneCtrl = TextEditingController(text: profile.phoneNumber ?? '');
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: _controller,
          builder: (ctx, _) {
            return _BottomSheet(
              title: 'Edit Profil',
              onClose: () => Navigator.pop(ctx),
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sheetField(
                      controller: nameCtrl,
                      label: 'Nama Lengkap',
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Nama tidak boleh kosong'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _sheetField(
                      controller: phoneCtrl,
                      label: 'Nomor Telepon',
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    _sheetField(controller: deptCtrl, label: 'Departemen'),
                    const SizedBox(height: 12),
                    _sheetField(controller: posCtrl, label: 'Jabatan'),
                    if (_controller.updateStatus == ProfileActionStatus.error)
                      _errorBanner(_controller.errorMessage ?? ''),
                    if (_controller.updateStatus == ProfileActionStatus.success)
                      _successBanner(_controller.successMessage ?? ''),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _controller.isUpdating
                            ? null
                            : () async {
                                if (!formKey.currentState!.validate()) return;
                                final updated = profile.copyWith(
                                  fullName: nameCtrl.text.trim(),
                                  department: deptCtrl.text.trim().isEmpty
                                      ? null
                                      : deptCtrl.text.trim(),
                                  position: posCtrl.text.trim().isEmpty
                                      ? null
                                      : posCtrl.text.trim(),
                                  phoneNumber: phoneCtrl.text.trim().isEmpty
                                      ? null
                                      : phoneCtrl.text.trim(),
                                );
                                final ok = await _controller.updateProfile(
                                  updated,
                                );
                                if (ok && ctx.mounted) {
                                  Navigator.pop(ctx);
                                  _controller.resetUpdate();
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
                        child: _controller.isUpdating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Simpan Perubahan',
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
      },
    ).whenComplete(_controller.resetUpdate);
  }

  // ─── CHANGE PASSWORD BOTTOM SHEET ─────────────────────────────────────────

  void _showChangePasswordSheet(BuildContext context) {
    final newPassCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var obscureNew = true;
    var obscureConfirm = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return ListenableBuilder(
              listenable: _controller,
              builder: (ctx, _) {
                return _BottomSheet(
                  title: 'Ubah Password',
                  onClose: () => Navigator.pop(ctx),
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sheetField(
                          controller: newPassCtrl,
                          label: 'Password Baru',
                          obscureText: obscureNew,
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureNew
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                            onPressed: () =>
                                setLocal(() => obscureNew = !obscureNew),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Password tidak boleh kosong';
                            }
                            if (v.length < 6) return 'Minimal 6 karakter';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        _sheetField(
                          controller: confirmCtrl,
                          label: 'Konfirmasi Password',
                          obscureText: obscureConfirm,
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureConfirm
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                            onPressed: () => setLocal(
                              () => obscureConfirm = !obscureConfirm,
                            ),
                          ),
                          validator: (v) {
                            if (v != newPassCtrl.text) {
                              return 'Password tidak sama';
                            }
                            return null;
                          },
                        ),
                        if (_controller.passwordStatus ==
                            ProfileActionStatus.error)
                          _errorBanner(_controller.errorMessage ?? ''),
                        if (_controller.passwordStatus ==
                            ProfileActionStatus.success)
                          _successBanner(_controller.successMessage ?? ''),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: _controller.isChangingPassword
                                ? null
                                : () async {
                                    if (!formKey.currentState!.validate()) {
                                      return;
                                    }
                                    final ok = await _controller.changePassword(
                                      newPassCtrl.text,
                                    );
                                    if (ok && ctx.mounted) {
                                      Navigator.pop(ctx);
                                      _controller.resetPassword();
                                      _showSnack(
                                        context,
                                        'Password berhasil diubah.',
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
                            child: _controller.isChangingPassword
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text(
                                    'Simpan Password',
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
          },
        );
      },
    ).whenComplete(_controller.resetPassword);
  }

  // ─── SHEET HELPERS ────────────────────────────────────────────────────────

  Widget _sheetField({
    required TextEditingController controller,
    required String label,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          fontSize: 13,
          color: AppColors.textSecondary,
        ),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: AppColors.background,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
      ),
    );
  }

  Widget _errorBanner(String msg) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.errorLight,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
    ),
    child: Text(
      msg,
      style: const TextStyle(fontSize: 13, color: AppColors.error),
    ),
  );

  Widget _successBanner(String msg) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.successLight,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.success.withValues(alpha: 0.3)),
    ),
    child: Text(
      msg,
      style: const TextStyle(fontSize: 13, color: AppColors.success),
    ),
  );

  void _showSnack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.success,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

// ─── BOTTOM SHEET WRAPPER ─────────────────────────────────────────────────────

class _BottomSheet extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback onClose;

  const _BottomSheet({
    required this.title,
    required this.child,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom > 0
        ? media.viewInsets.bottom + 20
        : (media.padding.bottom > 0
                  ? media.padding.bottom
                  : media.viewPadding.bottom) +
              28;
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.background,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
