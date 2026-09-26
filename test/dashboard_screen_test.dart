import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/l10n/generated/app_localizations.dart';
import 'package:vaultsync_client/features/emulation/presentation/dashboard_screen.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';

class MockSyncNotifier extends StateNotifier<SyncState> with Mock implements SyncNotifier {
  MockSyncNotifier() : super(SyncState());
  @override
  Future<void> refreshConflicts() async {}
}

void main() {
  testWidgets('DashboardScreen should show error banner when syncErrors is not empty', (tester) async {
    final mockSyncNotifier = MockSyncNotifier();
    
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((ref) => mockSyncNotifier),
          systemPathsProvider.overrideWith((ref) => Future.value(<String, String>{})),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: DashboardScreen(),
        ),
      ),
    );

    // Initial state: empty errors
    expect(find.textContaining('sync errors detected'), findsNothing);

    // Update state with errors
    mockSyncNotifier.state = SyncState(syncErrors: [
      UserFacingError(title: 'Custom Error Title', message: 'Message 1'),
    ]);
    await tester.pump();

    expect(find.textContaining('Custom Error Title'), findsOneWidget);
  });

  testWidgets(
      'DashboardScreen does not overflow when the error banner has a very long message',
      (tester) async {
    // Regression test for a real-device crash: "[VaultSync FATAL] A
    // RenderFlex overflowed by 17 pixels on the bottom." fired at the same
    // moment as a sync-error banner with a long, un-truncated message — the
    // banner grew tall enough to squeeze the rest of the dashboard's body
    // below the available height. flutter_test fails the test on any
    // RenderFlex overflow by default, so this test failing (without the
    // dashboard_screen.dart fix) reproduces the bug directly.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final mockSyncNotifier = MockSyncNotifier();
    final longDetail = List.filled(
      3,
      'FileSystemException: Cannot open file, path = '
          '/storage/emulated/0/Android/data/com.flycast.emulator/files/saves/'
          'really/long/nested/path/that/does/not/exist/save.bin '
          '(OS Error: No such file or directory, errno = 2)',
    ).join(' ');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((ref) => mockSyncNotifier),
          systemPathsProvider.overrideWith((ref) => Future.value(<String, String>{})),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: DashboardScreen(),
        ),
      ),
    );

    mockSyncNotifier.state = SyncState(syncErrors: [
      UserFacingError(
        title: 'Sync Failed',
        message: 'An unexpected error occurred while syncing Dreamcast. $longDetail',
        originalError: Exception(longDetail),
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);

    // The full text must still be reachable via the "Details" dialog.
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
