import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/settings/presentation/settings_screen.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockBackgroundSyncService extends Mock implements BackgroundSyncService {}

void main() {
  late MockBackgroundSyncService mockBackgroundSyncService;

  setUp(() {
    mockBackgroundSyncService = MockBackgroundSyncService();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Auto Sync toggle should call BackgroundSyncService', (tester) async {
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

    final toggleFinder = find.byType(SwitchListTile).at(1); // Auto Sync is the second switch
    expect(toggleFinder, findsOneWidget);

    when(() => mockBackgroundSyncService.enableAutoSync()).thenAnswer((_) async => Future.value());

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    verify(() => mockBackgroundSyncService.enableAutoSync()).called(1);
  });
}
