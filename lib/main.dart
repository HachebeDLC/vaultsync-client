import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'core/services/decky_bridge_service.dart';
import 'core/utils/offline_banner.dart';
import 'core/localization/locale_provider.dart';
import 'l10n/generated/app_localizations.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    developer.log('WORKER: Executing background task: $task', name: 'VaultSync', level: 800);
    
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

      // Initialize the logout callback so if we hit a 401 we can stop the madness
      apiClient.setForceLogoutCallback(() async {
        developer.log('WORKER: Force Logout triggered in background. Cancelling all future tasks.', name: 'VaultSync', level: 1000);
        await Workmanager().cancelAll();
      });

      // 1. Check if server is even configured
      if (!await apiClient.isConfigured()) {
        developer.log('WORKER: Server not configured. Skipping background sync.', name: 'VaultSync', level: 800);
        // We don't necessarily cancelAll here as the user might be mid-setup, 
        // but we return true to stop this specific execution.
        return true;
      }
      
      // 2. Check if we have an auth token
      final token = await apiClient.getToken();
      
      // If we've lost our session or logged out, stop the background worker permanently
      if (token == null || token.isEmpty) {
        developer.log('WORKER: No auth token found. User is logged out. Cancelling background tasks.', name: 'VaultSync', level: 900);
        await Workmanager().cancelAll();
        return true; 
      }

      final syncService = container.read(syncServiceProvider);
      
      // Perform a Fast Sync (timestamp based) for all systems
      await syncService.runSync(
        fastSync: true,
        isBackground: true,
        onProgress: (msg) => developer.log('WORKER: $msg', name: 'VaultSync', level: 800),
      );
      
      // Wait for any final log writes to complete
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      developer.log('WORKER FAILED', name: 'VaultSync', level: 1000, error: e);
      if (e is ApiException && (e.statusCode == 401 || e.statusCode == 403)) {
        developer.log('WORKER: Auth failed permanently. Cancelling background tasks.', name: 'VaultSync', level: 1000);
        await Workmanager().cancelAll();
      }
      return false;
    } finally {
      container.dispose();
    }
  });
}

/// One-time migration: copies SharedPreferences + SQLite DB from a bare Linux
/// install into the Flatpak sandbox data directory on first launch.
///
/// Must be called BEFORE the first [SharedPreferences.getInstance()] so the
/// migrated file is already in place when Flutter reads it.
Future<void> _migrateNativeToFlatpak() async {
  if (!Platform.isLinux) return;
  if (!File('/.flatpak-info').existsSync()) return; // not inside Flatpak

  final home = Platform.environment['HOME'];
  if (home == null) return;

  // XDG_DATA_HOME inside the Flatpak resolves to
  //   ~/.var/app/com.vaultsync.app/data/
  // path_provider maps getApplicationSupportDirectory() to
  //   $XDG_DATA_HOME/vaultsync_client/
  // The bare install stored everything in ~/.local/share/vaultsync_client/.
  final oldDir = Directory('$home/.local/share/vaultsync_client');
  if (!await oldDir.exists()) return;

  final xdgData = Platform.environment['XDG_DATA_HOME'] ??
      '$home/.var/app/com.vaultsync.app/data';
  final newDir = Directory('$xdgData/vaultsync_client');

  // Sentinel: skip if migration already ran.
  final sentinel = File('${newDir.path}/.migrated_from_native');
  if (await sentinel.exists()) return;

  await newDir.create(recursive: true);

  const filesToMigrate = [
    'shared_preferences.json',
    'sync_state.db',
    'sync_state.db-wal',
    'sync_state.db-shm',
  ];

  for (final name in filesToMigrate) {
    final src = File('${oldDir.path}/$name');
    if (await src.exists()) {
      await src.copy('${newDir.path}/$name');
      developer.log('MIGRATION: copied $name to Flatpak data dir',
          name: 'VaultSync', level: 800);
    }
  }

  await sentinel.writeAsString(DateTime.now().toIso8601String());
  developer.log('MIGRATION: native → Flatpak complete', name: 'VaultSync', level: 800);
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
    developer.log('Installed Linux desktop shortcut at ${desktopFile.path}', name: 'VaultSync', level: 800);
  } catch (e) {
    developer.log('Failed to install Linux shortcut', name: 'VaultSync', level: 900, error: e);
  }
}

void main() async {
  // Catch all unhandled async errors that escape the Dart runtime
  FlutterError.onError = (details) {
    // ignore: avoid_print
    print('[VaultSync FATAL] ${details.exceptionAsString()}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    // ignore: avoid_print
    print('[VaultSync UNHANDLED] $error\n$stack');
    return true;
  };

  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isLinux || Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  if (Platform.isLinux) {
    // Migration must run before SharedPreferences is first accessed.
    await _migrateNativeToFlatpak();
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

class VaultSyncApp extends ConsumerStatefulWidget {
  const VaultSyncApp({super.key});

  @override
  ConsumerState<VaultSyncApp> createState() => _VaultSyncAppState();
}

class _VaultSyncAppState extends ConsumerState<VaultSyncApp> {
  @override
  void initState() {
    super.initState();
    if (Platform.isLinux) {
      ref.read(deckyBridgeServiceProvider).start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);
    final router = ref.watch(routerProvider);
    final locale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'VaultSync',
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue, brightness: Brightness.dark),
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OfflineBanner(),
            ),
          ],
        );
      },
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
