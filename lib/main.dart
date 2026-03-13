import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/theme_provider.dart';
import 'core/services/api_client_provider.dart';
import 'features/auth/domain/auth_provider.dart';
import 'features/auth/presentation/auth_screen.dart';
import 'features/auth/presentation/recovery_setup_screen.dart';
import 'features/auth/presentation/recovery_screen.dart';
import 'features/startup/presentation/boot_screen.dart';
import 'features/startup/presentation/library_setup_screen.dart';
import 'features/startup/presentation/setup_screen.dart';
import 'features/emulation/presentation/dashboard_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/settings/presentation/diagnostics_screen.dart';
import 'features/sync/presentation/system_detail_screen.dart';
import 'features/sync/presentation/conflict_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: VaultSyncApp()));
}

class VaultSyncApp extends ConsumerWidget {
  const VaultSyncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'VaultSync',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue, brightness: Brightness.dark),
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

class AuthRefreshNotifier extends ChangeNotifier {
  AuthRefreshNotifier(ProviderRef ref) {
    ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

final authRefreshProvider = Provider((ref) => AuthRefreshNotifier(ref));

final routerProvider = Provider<GoRouter>((ref) {
  final refreshListenable = ref.read(authRefreshProvider);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refreshListenable,
    redirect: (context, state) async {
      final authState = ref.read(authProvider);
      final apiClient = ref.read(apiClientProvider);
      final baseUrl = await apiClient.getBaseUrl();
      
      final isBooting = state.matchedLocation == '/';
      final isSettingUp = state.matchedLocation == '/setup';
      final isLoggingIn = state.matchedLocation == '/auth';
      final isOnRecovery = state.matchedLocation.startsWith('/auth/recovery');
      
      // 1. Initial Boot Screen
      if (isBooting) return null;

      // 2. FORCE SETUP: If no URL is configured, force /setup
      if ((baseUrl == null || baseUrl.isEmpty) && !isSettingUp) {
        return '/setup';
      }

      // 3. AUTH GUARD: If logged out and not on auth/recovery/setup, force /auth
      if (authState == null && !isLoggingIn && !isOnRecovery && !isSettingUp) {
        return '/auth';
      }
      
      // 4. LOGGED IN: If logged in and trying to go to auth or setup, skip to dashboard
      if (authState != null && (isLoggingIn || isSettingUp)) {
        return '/dashboard';
      }

      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const BootScreen()),
      GoRoute(path: '/setup', builder: (context, state) => const SetupScreen()),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
        routes: [
          GoRoute(path: 'recovery-setup', builder: (context, state) => const RecoverySetupScreen()),
          GoRoute(path: 'recovery', builder: (context, state) => const RecoveryScreen()),
        ],
      ),
      
      GoRoute(path: '/dashboard', builder: (context, state) => const DashboardScreen()),
      GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
      GoRoute(path: '/library-setup', builder: (context, state) => const LibrarySetupScreen()),
      GoRoute(
        path: '/system-detail/:id',
        builder: (context, state) => SystemDetailScreen(systemId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/diagnostics', builder: (context, state) => const DiagnosticsScreen()),
      GoRoute(path: '/conflicts', builder: (context, state) => const ConflictScreen()),
    ],
  );
});
