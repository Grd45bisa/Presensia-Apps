import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/providers/notification_provider.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/realtime_sync_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';
import '../../main_nav/main_screen.dart';
import '../controller/auth_controller.dart';
import 'forgot_password_screen.dart';
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

    final uid = AuthService.instance.currentUserId;
    AppStore.instance
        .loadFromCloud()
        .then((_) {
          NotificationProvider.instance.refresh();
        })
        .catchError((_) {});
    if (uid != null) RealtimeSyncService.instance.subscribe(uid);

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
                      : (height * 0.54).clamp(330.0, 420.0);

                  return Stack(
                    children: [
                      _buildBackground(panelTop + 92),
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        top: keyboardOpen ? panelTop - 92 : panelTop - 118,
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
          padding: EdgeInsets.fromLTRB(28, keyboardOpen ? 30 : 24, 28, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeading(),
                    const SizedBox(height: 24),
                    _buildEmailField(),
                    const SizedBox(height: 16),
                    _buildPasswordField(),
                    if (_controller.errorMessage != null) ...[
                      const SizedBox(height: 16),
                      ErrorBanner(message: _controller.errorMessage!),
                    ],
                    const SizedBox(height: 18),
                    _buildActionRow(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeading() {
    return const Column(
      children: [
        Text(
          'Selamat datang!',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            height: 1.05,
            fontWeight: FontWeight.w900,
            color: AppColors.textPrimary,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Masuk untuk mulai presensi dan\nmemantau aktivitas kerjamu',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.32,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildEmailField() {
    return _SketchField(
      controller: _emailCtrl,
      hint: 'Email',
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

  Widget _buildPasswordField() {
    return _SketchField(
      controller: _passCtrl,
      hint: 'Password',
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

  Widget _buildActionRow() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
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
              padding: const EdgeInsets.symmetric(horizontal: 16),
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
                      Icon(Icons.login_rounded, size: 14),
                      SizedBox(width: 8),
                      Text(
                        'Masuk',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _goForgotPassword,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text.rich(
              TextSpan(
                text: 'Lupa password? ',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary.withValues(alpha: 0.9),
                ),
                children: const [
                  TextSpan(
                    text: 'Reset di sini',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}

class _SketchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final Iterable<String>? autofillHints;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final void Function(String)? onChanged;
  final void Function(String)? onFieldSubmitted;

  const _SketchField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.next,
    this.autofillHints,
    this.suffixIcon,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted,
        style: const TextStyle(
          fontSize: 15,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontSize: 15,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
          prefixIcon: Icon(icon, size: 20, color: AppColors.primary),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 48,
            minHeight: 56,
          ),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: AppColors.background,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: _border(AppColors.border),
          enabledBorder: _border(AppColors.border),
          focusedBorder: _border(AppColors.primary, width: 1.5),
          errorBorder: _border(AppColors.error),
          focusedErrorBorder: _border(AppColors.error, width: 1.5),
          errorStyle: const TextStyle(fontSize: 11, color: AppColors.error),
        ),
        validator: validator,
      ),
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
