import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/theme/theme_provider.dart';
import 'core/services/api_client_provider.dart';
import 'core/services/api_client.dart';
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
    
    // Initialize a lightweight container for background sync.
    // We override essential providers to avoid instantiating the full UI-heavy graph.
    final container = ProviderContainer(
      overrides: [
        // We can keep default providers if they are lightweight, but 
        // explicit overrides ensure we don't accidentally pull in UI logic.
        apiClientProvider.overrideWith((ref) => ApiClient()),
      ],
    );

    try {
      final apiClient = container.read(apiClientProvider);

      // 1. Check if server is even configured
      if (!await apiClient.isConfigured()) {
        print("🕒 WORKER: Server not configured. Skipping background sync.");
        // We don't necessarily cancelAll here as the user might be mid-setup, 
        // but we return true to stop this specific execution.
        return true;
      }
      
      // 2. Check if we have an auth token
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

Future<void> _installLinuxShortcut() async {
  if (!Platform.isLinux) return;
  try {
    final exePath = Platform.resolvedExecutable;
    if (!exePath.contains('VaultSync')) return; // Don't install during dev/test

    final dir = File(exePath).parent.path;
    final home = Platform.environment['HOME'];
    if (home == null) return;
    
    final desktopDir = Directory('$home/.local/share/applications');
    if (!await desktopDir.exists()) {
      await desktopDir.create(recursive: true);
    }
    
    final desktopFile = File('${desktopDir.path}/vaultsync.desktop');
    final content = '''[Desktop Entry]
Version=1.0
Name=VaultSync
Comment=High-performance emulator save synchronization
Exec=$exePath
Icon=$dir/data/flutter_assets/assets/vaultsync_icon.png
Terminal=false
Type=Application
Categories=Utility;Game;
''';
    
    // Only write if it's different to save disk I/O
    if (await desktopFile.exists()) {
      final currentContent = await desktopFile.readAsString();
      if (currentContent == content) return;
    }
    
    await desktopFile.writeAsString(content);
    await Process.run('chmod', ['+x', desktopFile.path]);
    print('✅ Installed Linux desktop shortcut at ${desktopFile.path}');
  } catch (e) {
    print('⚠️ Failed to install Linux shortcut: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isLinux || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  if (Platform.isLinux) {
    await _installLinuxShortcut();
  }

  if (Platform.isAndroid || Platform.isIOS) {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: true,
    );
  }

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
