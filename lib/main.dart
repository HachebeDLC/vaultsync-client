import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';
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
import 'features/sync/presentation/sync_history_screen.dart';
import 'features/sync/services/sync_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("🕒 WORKER: Executing background task: $task");
    
    // Initialize a temporary container for background sync
    final container = ProviderContainer();
    try {
      final apiClient = container.read(apiClientProvider);
      final token = await apiClient.getToken();
      
      // If we've lost our session or logged out, stop the background worker permanently
      if (token == null || token.isEmpty) {
        print("🕒 WORKER: No auth token found. User is logged out. Cancelling background tasks.");
        await Workmanager().cancelAll();
        return true; 
      }

      final syncService = container.read(syncServiceProvider);
      
      // Perform a Fast Sync (timestamp based) for all systems
      await syncService.runSync(
        fastSync: true,
        isBackground: true,
        onProgress: (msg) => print("🕒 WORKER: $msg"),
      );
      
      // Wait for any final log writes to complete
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      print("❌ WORKER FAILED: $e");
      return false;
    } finally {
      container.dispose();
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: true,
  );

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
      
      if (isBooting) return null;
      if ((baseUrl == null || baseUrl.isEmpty) && !isSettingUp) return '/setup';
      if (authState == null && !isLoggingIn && !isOnRecovery && !isSettingUp) return '/auth';
      if (authState != null && (isLoggingIn || isSettingUp)) return '/dashboard';

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
      GoRoute(path: '/history', builder: (context, state) => const SyncHistoryScreen()),
    ],
  );
});
