import 'package:flutter/material.dart';
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
  late MockBackgroundSyncService mockBackgroundSyncService;
  late MockDesktopBackgroundSyncService mockDesktopBackgroundSyncService;

  setUp(() {
    mockBackgroundSyncService = MockBackgroundSyncService();
    mockDesktopBackgroundSyncService = MockDesktopBackgroundSyncService();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Auto Sync toggle should call appropriate sync service', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backgroundSyncServiceProvider.overrideWith((ref) => mockBackgroundSyncService),
          desktopBackgroundSyncServiceProvider.overrideWith((ref) => mockDesktopBackgroundSyncService),
        ],
        child: const MaterialApp(
          home: SettingsScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final toggleFinder = find.byType(SwitchListTile).at(1); // Auto Sync is the second switch
    expect(toggleFinder, findsOneWidget);

    if (Platform.isAndroid || Platform.isIOS) {
      when(() => mockBackgroundSyncService.startMonitoring()).thenAnswer((_) async => Future.value());
    } else {
      when(() => mockDesktopBackgroundSyncService.startAutoSync()).thenReturn(null);
    }

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    if (Platform.isAndroid || Platform.isIOS) {
      verify(() => mockBackgroundSyncService.startMonitoring()).called(1);
    } else {
      verify(() => mockDesktopBackgroundSyncService.startAutoSync()).called(1);
    }
  });
}
