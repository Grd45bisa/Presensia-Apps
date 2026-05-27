import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../../shared/providers/notification_provider.dart';
import '../../../shared/services/auth_service.dart';
import '../../../shared/services/realtime_sync_service.dart';
import '../../../shared/store/app_store.dart';
import '../../../shared/theme/app_colors.dart';
import '../../main_nav/main_screen.dart';
import 'login_screen.dart';
import 'widgets/auth_widgets.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const double _exitStart = 0.7436;
  static const Duration _cloudReadyTimeout = Duration(seconds: 8);
  static const Duration _connectivityTimeout = Duration(seconds: 3);

  late final AnimationController _anim;
  late final Animation<double> _brandProgress;
  late final Animation<double> _subtitleProgress;
  late final Animation<double> _exitProgress;
  late final Future<void> _introFuture;
  bool _checkingSession = false;
  bool _didNavigate = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1950),
    );
    _brandProgress = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.1538, 0.3846, curve: Curves.easeInOutCubic),
    );
    _subtitleProgress = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.4359, 0.6154, curve: Curves.easeOutCubic),
    );
    _exitProgress = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.7436, 1.0, curve: Curves.easeInOutCubic),
    );
    _introFuture = _playIntroAnimation();
    unawaited(_checkSession());
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _playIntroAnimation() async {
    await WidgetsBinding.instance.endOfFrame;
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    try {
      await _anim.animateTo(_exitStart).orCancel;
    } on TickerCanceled {
      // Splash sudah ditutup sebelum animasi selesai.
    }
  }

  Future<void> _playExitAnimation() async {
    if (!mounted) return;
    try {
      await _anim
          .animateTo(
            1,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      // Splash sudah ditutup sebelum animasi selesai.
    }
  }

  Future<void> _checkSession() async {
    if (_checkingSession || _didNavigate) return;
    _checkingSession = true;
    try {
      await _introFuture;
      if (!mounted) return;

      while (mounted && !_didNavigate) {
        if (!await _isOnline()) {
          await _showNoInternetDialog();
          continue;
        }

        final screen = await _prepareStartScreen();
        if (!mounted) return;

        await _playExitAnimation();
        if (!mounted) return;

        _navigate(screen);
        return;
      }
    } catch (_) {
      if (!mounted) return;
      _activateSignedInServices();
      await _playExitAnimation();
      if (!mounted) return;
      _navigate(_fallbackStartScreen());
    } finally {
      _checkingSession = false;
    }
  }

  Future<Widget> _prepareStartScreen() async {
    if (AuthService.instance.isSignedIn) {
      try {
        await AppStore.instance.loadFromCloud().timeout(_cloudReadyTimeout);
      } catch (_) {
        // Jangan tahan splash selamanya. Data bisa tersinkron setelah screen utama hidup.
      }
      _activateSignedInServices();
      return const MainScreen();
    }

    return const LoginScreen();
  }

  void _activateSignedInServices() {
    if (!AuthService.instance.isSignedIn) return;
    final uid = AuthService.instance.currentUserId;
    NotificationProvider.instance.refresh();
    if (uid != null) RealtimeSyncService.instance.subscribe(uid);
  }

  Widget _fallbackStartScreen() {
    return AuthService.instance.isSignedIn
        ? const MainScreen()
        : const LoginScreen();
  }

  Future<bool> _isOnline() async {
    if (kIsWeb) return true;

    final result = await Connectivity().checkConnectivity().timeout(
      _connectivityTimeout,
      onTimeout: () {
        return [ConnectivityResult.wifi];
      },
    );
    return result.any((r) => r != ConnectivityResult.none);
  }

  Future<void> _showNoInternetDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
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
                    color: AppColors.warning.withValues(alpha: 0.18),
                    width: 1.2,
                  ),
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 36,
                  color: AppColors.warning,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Koneksi Internet Terputus',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Aktifkan Wi-Fi atau data seluler agar aplikasi bisa memuat akun dan sinkronisasi data terbaru.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: const Text(
                    'Coba Lagi',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Kami akan mengecek ulang koneksi setelah tombol ditekan.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigate(Widget screen) {
    if (_didNavigate || !mounted) return;
    _didNavigate = true;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (ctx, a1, a2) => screen,
        transitionsBuilder: (ctx, anim, a2, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: _AnimatedPresensiaLogo(
            brandProgress: _brandProgress,
            subtitleProgress: _subtitleProgress,
            exitProgress: _exitProgress,
          ),
        ),
      ),
    );
  }
}

class _AnimatedPresensiaLogo extends StatelessWidget {
  const _AnimatedPresensiaLogo({
    required this.brandProgress,
    required this.subtitleProgress,
    required this.exitProgress,
  });

  final Animation<double> brandProgress;
  final Animation<double> subtitleProgress;
  final Animation<double> exitProgress;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final scale = (width / 390).clamp(0.86, 1.08);
    final logoSize = 72.0 * scale;
    final textGap = 7.0 * scale;
    final titleWidth = 170.0 * scale;
    final fullLockupWidth = logoSize + textGap + titleWidth;
    final titleStyle = TextStyle(
      color: Colors.black,
      fontSize: 33 * scale,
      fontWeight: FontWeight.w800,
      height: 0.98,
      letterSpacing: 0,
    );
    final subtitleStyle = TextStyle(
      color: Colors.black,
      fontSize: 8.5 * scale,
      fontWeight: FontWeight.w700,
      height: 1.0,
      letterSpacing: 0,
    );

    return AnimatedBuilder(
      animation: Listenable.merge([
        brandProgress,
        subtitleProgress,
        exitProgress,
      ]),
      builder: (context, _) {
        final brandT = brandProgress.value;
        final subtitleT = subtitleProgress.value;
        final exitT = exitProgress.value;
        final canvasWidth = 300 * scale;
        final finalLogoLeft = (canvasWidth - fullLockupWidth) / 2;
        final initialLogoLeft = (canvasWidth - logoSize) / 2;
        final logoLeft = _lerp(initialLogoLeft, finalLogoLeft, brandT);
        final titleLeft = logoLeft + logoSize + textGap;
        final textRevealWidth = titleWidth * brandT;
        final titleHeight = 33 * scale * 0.98;
        final logoCenterY = 42 * scale;
        final centeredTitleTop = logoCenterY - (titleHeight / 2);
        final finalTitleTop = 15 * scale;
        final titleTop = _lerp(centeredTitleTop, finalTitleTop, subtitleT);
        final subtitleTop = _lerp(
          centeredTitleTop + titleHeight - (3 * scale),
          50 * scale,
          subtitleT,
        );

        return Opacity(
          opacity: 1 - exitT,
          child: Transform.translate(
            offset: Offset(0, _lerp(0, 34 * scale, exitT)),
            child: SizedBox(
              width: canvasWidth,
              height: 100 * scale,
              child: Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: canvasWidth,
                  height: 84 * scale,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.centerLeft,
                    children: [
                      Positioned(
                        left: logoLeft,
                        top: 6 * scale,
                        child: SizedBox(
                          width: logoSize,
                          height: logoSize,
                          child: Image.asset(
                            AuthAssets.logoTransparent,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ),
                      Positioned(
                        left: titleLeft,
                        top: titleTop,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: brandT.clamp(0.0, 1.0),
                            child: Text('Presensia', style: titleStyle),
                          ),
                        ),
                      ),
                      Positioned(
                        left: titleLeft + (1.5 * scale),
                        top: subtitleTop,
                        child: Transform.translate(
                          offset: Offset(0, _lerp(-4 * scale, 0, subtitleT)),
                          child: Opacity(
                            opacity: subtitleT,
                            child: SizedBox(
                              width: textRevealWidth,
                              child: Text(
                                'Presensi wajah & produktivitas',
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: subtitleStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _lerp(double begin, double end, double t) {
    return begin + (end - begin) * t;
  }
}
