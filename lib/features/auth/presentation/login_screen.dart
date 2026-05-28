import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/providers/notification_provider.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/device_session_service.dart';
import '../../../shared/services/realtime_sync_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';
import '../../main_nav/main_screen.dart';
import '../controller/auth_controller.dart';
import 'forgot_password_screen.dart';
import 'qr_login_screen.dart';
import 'widgets/auth_widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _controller = AuthController();
  bool _obscure = true;
  bool _showAdminLogin = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_controller.isLoading) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final ok = await _controller.signIn(
      email: _emailCtrl.text.trim(),
      password: _passCtrl.text,
    );

    if (!ok || !mounted) return;

    _finishLogin();
  }

  Future<void> _openQrLogin() async {
    if (_controller.isLoading) return;
    FocusScope.of(context).unfocus();
    final loggedIn = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const QrLoginScreen()),
    );
    if (loggedIn == true && mounted) _finishLogin();
  }

  void _finishLogin() {
    final uid = AuthService.instance.currentUserId;
    AppStore.instance
        .loadFromCloud()
        .then((_) {
          NotificationProvider.instance.refresh();
        })
        .catchError((_) {});
    if (uid != null) RealtimeSyncService.instance.subscribe(uid);
    DeviceSessionService.instance.start();

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const MainScreen(),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  void _goForgotPassword() {
    _controller.reset();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
    );
  }

  void _toggleAdminMode() {
    setState(() {
      _showAdminLogin = !_showAdminLogin;
      _controller.reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final keyboardOpen = viewInsets.bottom > 0;

    return Scaffold(
      backgroundColor: AppColors.surface,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            return AutofillGroup(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final height = constraints.maxHeight;
                  final panelTop = keyboardOpen
                      ? (height * 0.38).clamp(198.0, 264.0)
                      : (height * 0.48).clamp(296.0, 374.0);

                  return Stack(
                    children: [
                      _buildBackground(panelTop + 92),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        top: keyboardOpen ? panelTop - 92 : panelTop - 110,
                        left: 0,
                        right: 0,
                        child: _buildHeroBrand(compact: keyboardOpen),
                      ),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        left: 0,
                        right: 0,
                        top: panelTop,
                        bottom: 0,
                        child: _buildFormPanel(keyboardOpen: keyboardOpen),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBackground(double height) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: height,
      child: ColoredBox(
        color: AppColors.primaryLight,
        child: Opacity(
          opacity: 0.65,
          child: Transform.translate(
            offset: const Offset(0, -48),
            child: Image.asset(
              'public/Background-login.png',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroBrand({required bool compact}) {
    final logoSize = compact ? 48.0 : 64.0;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            AuthAssets.logoTransparent,
            width: logoSize,
            height: logoSize,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Presensia',
                style: TextStyle(
                  fontSize: 26,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Presensi wajah & Produktivitas',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormPanel({required bool keyboardOpen}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(38)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDark.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.fromLTRB(26, keyboardOpen ? 26 : 24, 26, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.05, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: _showAdminLogin
                    ? _buildAdminLoginState(keyboardOpen: keyboardOpen)
                    : _buildEmployeeLoginState(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmployeeLoginState() {
    return Column(
      key: const ValueKey('employee_state'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Selamat datang!',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            height: 1.05,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Masuk dengan QR atau email yang terdaftar.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.32,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 32),
        _buildQrButton(),
        const SizedBox(height: 24),
        Center(
          child: TextButton.icon(
            onPressed: _toggleAdminMode,
            icon: const Icon(Icons.admin_panel_settings_outlined, size: 18),
            label: const Text('Masuk Dengan Email'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAdminLoginState({required bool keyboardOpen}) {
    return KeyedSubtree(
      key: const ValueKey('admin_state'),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _toggleAdminMode,
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: AppColors.textPrimary,
                  tooltip: 'Kembali',
                ),
                const Expanded(
                  child: Text(
                    'Login Email',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 48), // Balance for back button
              ],
            ),
            SizedBox(height: keyboardOpen ? 16 : 24),
            _buildEmailField(),
            const SizedBox(height: 14),
            _buildPasswordField(),
            if (_controller.errorMessage != null) ...[
              const SizedBox(height: 16),
              ErrorBanner(message: _controller.errorMessage!),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: _goForgotPassword,
                  child: Text(
                    'Lupa Password?',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: _controller.isLoading
                      ? null
                      : () {
                          TextInput.finishAutofillContext();
                          _submit();
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    disabledBackgroundColor: AppColors.primary.withValues(
                      alpha: 0.55,
                    ),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ),
                  child: _controller.isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.login_rounded, size: 16),
                            SizedBox(width: 8),
                            Text(
                              'Masuk',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailField() {
    return AuthField(
      controller: _emailCtrl,
      label: 'Email',
      icon: Icons.email_outlined,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      onChanged: (_) => _controller.reset(),
      validator: (v) {
        if (v == null || v.trim().isEmpty) {
          return 'Email tidak boleh kosong';
        }
        if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim())) {
          return 'Format email tidak valid';
        }
        return null;
      },
    );
  }

  Widget _buildQrButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openQrLogin,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          height: 78,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E88E5), Color(0xFF1565C0)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.qr_code_scanner_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Masuk Scan QRCode',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Scan QR dari dashboard admin',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return AuthField(
      controller: _passCtrl,
      label: 'Password',
      icon: Icons.lock_outline_rounded,
      obscureText: _obscure,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.password],
      onFieldSubmitted: (_) => _submit(),
      onChanged: (_) => _controller.reset(),
      suffixIcon: IconButton(
        icon: Icon(
          _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          color: AppColors.textSecondary,
          size: 18,
        ),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
      validator: (v) {
        if (v == null || v.isEmpty) {
          return 'Password tidak boleh kosong';
        }
        return null;
      },
    );
  }
}
