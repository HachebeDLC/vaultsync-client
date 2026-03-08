import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';

void main() {
  group('SyncState', () {
    test('should initialize with empty syncErrors', () {
      final state = SyncState();
      expect(state.syncErrors, isEmpty);
    });

    test('copyWith should update syncErrors', () {
      final state = SyncState();
      final newState = state.copyWith(syncErrors: ['Error 1']);
      expect(newState.syncErrors, ['Error 1']);
    });
  });
}
