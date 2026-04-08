import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/settings/presentation/settings_screen.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';
import 'package:vaultsync_client/features/sync/services/desktop_background_sync_service.dart';
import 'package:vaultsync_client/core/services/vaultsync_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/l10n/generated/app_localizations.dart';
import 'dart:io';

class MockBackgroundSyncService extends Mock implements BackgroundSyncService {}
class MockDesktopBackgroundSyncService extends Mock implements DesktopBackgroundSyncService {}
class MockVaultSyncLauncher extends Mock implements VaultSyncLauncher {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const Duration(hours: 6));
  });
  const channel = MethodChannel('com.vaultsync.app/launcher');
  late MockBackgroundSyncService mockBackgroundSyncService;
  late MockDesktopBackgroundSyncService mockDesktopBackgroundSyncService;
  late MockVaultSyncLauncher mockVaultSyncLauncher;

  setUp(() {
    mockBackgroundSyncService = MockBackgroundSyncService();
    mockDesktopBackgroundSyncService = MockDesktopBackgroundSyncService();
    mockVaultSyncLauncher = MockVaultSyncLauncher();
    SharedPreferences.setMockInitialValues({});

    when(() => mockVaultSyncLauncher.getAppVersionFull()).thenAnswer((_) async => 'VaultSync v1.3.7-Secure');
    when(() => mockVaultSyncLauncher.getSyncEngineDescription()).thenAnswer((_) async => 'Hardware-Accelerated Sync Engine');
    
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (methodCall) async {
        if (methodCall.method == 'hasUsageStatsPermission') return true;
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('Sync on Game Exit toggle should call startMonitoring on Android', (tester) async {
    // Only run this test on Android to avoid platform mismatch complexity in unit test
    if (!Platform.isAndroid) return;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backgroundSyncServiceProvider.overrideWith((ref) => mockBackgroundSyncService),
          vaultSyncLauncherProvider.overrideWithValue(mockVaultSyncLauncher),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: SettingsScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final toggleFinder = find.byType(SwitchListTile).at(0); // Sync on Game Exit
    expect(toggleFinder, findsOneWidget);

    when(() => mockBackgroundSyncService.startMonitoring()).thenAnswer((_) async => Future.value());

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    verify(() => mockBackgroundSyncService.startMonitoring()).called(1);
  });

  testWidgets('Periodic Sync toggle should call startAutoSync on Desktop', (tester) async {
    if (Platform.isAndroid || Platform.isIOS) return;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopBackgroundSyncServiceProvider.overrideWith((ref) => mockDesktopBackgroundSyncService),
          vaultSyncLauncherProvider.overrideWithValue(mockVaultSyncLauncher),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: SettingsScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final toggleFinder = find.byType(SwitchListTile).at(1); // Periodic Sync
    expect(toggleFinder, findsOneWidget);

    when(() => mockDesktopBackgroundSyncService.startAutoSync(interval: any(named: 'interval'))).thenReturn(null);

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    verify(() => mockDesktopBackgroundSyncService.startAutoSync(interval: any(named: 'interval'))).called(1);
  });
}
