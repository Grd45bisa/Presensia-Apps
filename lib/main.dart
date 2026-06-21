import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'features/auth/presentation/reset_password_screen.dart';
import 'features/auth/presentation/splash_screen.dart';
import 'features/main_nav/main_screen.dart';
import 'shared/database/session_cache_db.dart';
import 'shared/providers/notification_provider.dart';
import 'shared/services/attendance_dev_settings.dart';
import 'shared/services/auth_service.dart';
import 'shared/services/device_session_service.dart';
import 'shared/services/notification_service.dart';
import 'shared/services/realtime_sync_service.dart';
import 'shared/services/supabase_client.dart';
import 'shared/store/app_store.dart';
import 'shared/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  await SupabaseClientService.initialize();
  AttendanceDevSettings.instance.startDatabaseSync();
  runApp(const PresensiaApp());
  unawaited(_bootstrapBackgroundServices());
}

Future<void> _bootstrapBackgroundServices() async {
  if (kIsWeb) return;
  try {
    await NotificationService.instance.init().timeout(
      const Duration(seconds: 6),
    );
  } catch (_) {}

  try {
    // Safety net: pastikan alarm terjadwal tetap ter-arm walaupun app lama
    // tidak sempat dibuka (mis. setelah update atau force-stop).
    await NotificationService.instance.rearmFromSnapshot().timeout(
      const Duration(seconds: 4),
    );
  } catch (_) {}
}

class PresensiaApp extends StatefulWidget {
  const PresensiaApp({super.key});

  @override
  State<PresensiaApp> createState() => _PresensiaAppState();
}

class _PresensiaAppState extends State<PresensiaApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();

  // Event signedIn pertama saat app buka = restore session → SplashScreen yang handle.
  // Event signedIn setelah itu = login baru dari user → listener yang handle.
  bool _initialSignedInSkipped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenAuthState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save session cache when the app is about to be destroyed or goes to background.
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused) {
      AppStore.instance.saveToCache();
    }
  }

  void _listenAuthState() {
    AuthService.instance.authStateChanges.listen((state) {
      final nav = _navigatorKey.currentState;
      if (nav == null) return;

      switch (state.event) {
        case AuthChangeEvent.signedIn:
          // Skip event signedIn pertama (restore session) — SplashScreen yang handle.
          if (!_initialSignedInSkipped) {
            _initialSignedInSkipped = true;
            return;
          }
          AppStore.instance
              .loadFromCloud()
              .then((_) {
                NotificationProvider.instance.refresh();
              })
              .catchError((_) {});
          final uid = AuthService.instance.currentUserId;
          if (uid != null) RealtimeSyncService.instance.subscribe(uid);
          DeviceSessionService.instance.start();
          if (!_isOnResetScreen()) {
            nav.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MainScreen()),
              (_) => false,
            );
          }

        case AuthChangeEvent.passwordRecovery:
          nav.push(
            MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
          );

        case AuthChangeEvent.signedOut:
          _initialSignedInSkipped = false;
          DeviceSessionService.instance.stop();
          RealtimeSyncService.instance.unsubscribe();
          AppStore.instance.clear();
          SessionCacheDb.instance.clear();
          nav.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const SplashScreen()),
            (_) => false,
          );

        default:
          break;
      }
    });
  }

  bool _isOnResetScreen() {
    bool isReset = false;
    _navigatorKey.currentState?.popUntil((route) {
      if (route.settings.name == '/reset-password') isReset = true;
      return true;
    });
    return isReset;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Presensia',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: _navigatorKey,
      home: const SplashScreen(),
    );
  }
}
