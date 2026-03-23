import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/domain/sync_provider.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';

void main() {
  group('SyncState', () {
    test('should initialize with empty syncErrors', () {
      final state = SyncState();
      expect(state.syncErrors, isEmpty);
    });

    test('copyWith should update syncErrors', () {
      final error = UserFacingError(title: 'Error', message: 'Message 1');
      final state = SyncState();
      final newState = state.copyWith(syncErrors: [error]);
      expect(newState.syncErrors, [error]);
    });
  });
}
