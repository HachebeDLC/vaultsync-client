import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/settings/presentation/settings_screen.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';
import 'package:vaultsync_client/features/sync/services/desktop_background_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class MockBackgroundSyncService extends Mock implements BackgroundSyncService {}
class MockDesktopBackgroundSyncService extends Mock implements DesktopBackgroundSyncService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const Duration(hours: 6));
  });
  const channel = MethodChannel('com.vaultsync.app/launcher');
  late MockBackgroundSyncService mockBackgroundSyncService;
  late MockDesktopBackgroundSyncService mockDesktopBackgroundSyncService;

  setUp(() {
    mockBackgroundSyncService = MockBackgroundSyncService();
    mockDesktopBackgroundSyncService = MockDesktopBackgroundSyncService();
    SharedPreferences.setMockInitialValues({});
    
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
        ],
        child: const MaterialApp(
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
        ],
        child: const MaterialApp(
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
