import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'core/router/app_router.dart';
import 'core/theme/theme_provider.dart';
import 'core/services/notification_service.dart';
import 'features/sync/background/sync_worker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  await Workmanager().initialize(
    callbackDispatcher,
  );
  
  runApp(
    const ProviderScope(
      child: VaultSyncApp(),
      ),
      );
      }

      class VaultSyncApp extends ConsumerWidget {
      const VaultSyncApp({super.key});

      @override
      Widget build(BuildContext context, WidgetRef ref) {
      final theme = ref.watch(themeProvider);

      return MaterialApp.router(
      title: 'VaultSync',
      themeMode: theme,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple, brightness: Brightness.dark),
      routerConfig: goRouter,
    );
  }
}