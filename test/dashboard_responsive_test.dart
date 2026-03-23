import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultsync_client/features/emulation/presentation/dashboard_screen.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:mocktail/mocktail.dart';

class MockSyncNotifier extends StateNotifier<SyncState> with Mock implements SyncNotifier {
  MockSyncNotifier() : super(SyncState());
  @override
  Future<void> refreshConflicts() async {}
}

void main() {
  testWidgets('DashboardScreen should show NavigationRail on desktop', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;

    final mockSyncNotifier = MockSyncNotifier();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncProvider.overrideWith((ref) => mockSyncNotifier),
          systemPathsProvider.overrideWith((ref) => Future.value(<String, String>{
            'ps2': '/test/path/ps2',
          })),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(Row), findsWidgets);
    expect(find.byType(VerticalDivider), findsOneWidget);
    
    addTearDown(tester.view.resetPhysicalSize);
  });
}
