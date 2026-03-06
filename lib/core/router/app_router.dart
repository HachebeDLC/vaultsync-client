import 'package:go_router/go_router.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/emulation/domain/emulator_config.dart';
import '../../features/emulation/presentation/dashboard_screen.dart';
import '../../features/emulation/presentation/emulator_list_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/startup/presentation/boot_screen.dart';
import '../../features/startup/presentation/setup_screen.dart';
import '../../features/startup/presentation/library_setup_screen.dart';
import '../../features/sync/presentation/sync_screen.dart';
import '../../features/sync/presentation/system_detail_screen.dart';

final goRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const BootScreen(),
    ),
    GoRoute(
      path: '/setup',
      builder: (context, state) => const SetupScreen(),
    ),
    GoRoute(
      path: '/library-setup',
      builder: (context, state) => const LibrarySetupScreen(),
    ),
    GoRoute(
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      path: '/dashboard',
      builder: (context, state) => const DashboardScreen(),
    ),
    GoRoute(
      path: '/system-detail/:id',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return SystemDetailScreen(systemId: id);
      },
    ),
    GoRoute(
      path: '/sync',
      builder: (context, state) => const SyncScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/emulators/:id',
      builder: (context, state) {
        final system = state.extra as EmulatorConfig;
        return EmulatorListScreen(system: system);
      },
    ),
  ],
);
