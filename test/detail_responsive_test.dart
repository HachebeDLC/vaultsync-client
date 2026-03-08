import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultsync_client/features/sync/presentation/system_detail_screen.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';
import 'package:mocktail/mocktail.dart';

class MockSyncNotifier extends StateNotifier<SyncState> with Mock implements SyncNotifier {
  MockSyncNotifier() : super(SyncState());
  @override
  Future<void> refreshConflicts() async {}
}

void main() {
  testWidgets('SystemDetailScreen should render', (tester) async {
    final mockSyncNotifier = MockSyncNotifier();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((ref) => mockSyncNotifier),
        ],
        child: const MaterialApp(
          home: SystemDetailScreen(systemId: 'ps2'),
        ),
      ),
    );

    expect(find.textContaining('PS2'), findsWidgets);
  });
}
