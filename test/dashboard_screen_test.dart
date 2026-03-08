import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/emulation/presentation/dashboard_screen.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

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
          home: DashboardScreen(),
        ),
      ),
    );

    // Initial state: empty errors
    expect(find.textContaining('sync errors detected'), findsNothing);

    // Update state with errors
    mockSyncNotifier.state = SyncState(syncErrors: ['Error 1']);
    await tester.pump();

    expect(find.textContaining('1 sync errors detected'), findsOneWidget);
  });
}
