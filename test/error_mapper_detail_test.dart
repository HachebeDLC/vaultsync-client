import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';
import 'package:vaultsync_client/features/sync/domain/sync_log_provider.dart';

void main() {
  group('MissingSyncFolderException / ErrorMapper (item 2)', () {
    test('maps to a specific, actionable "Folder Not Found" error', () {
      final error = MissingSyncFolderException(
          'dc', '/storage/emulated/0/Android/data/com.flycast.emulator/files');

      final userError = ErrorMapper.map(error);

      expect(userError.title, 'Folder Not Found');
      expect(userError.message, contains('dc'));
      expect(userError.message,
          contains('/storage/emulated/0/Android/data/com.flycast.emulator/files'));
      expect(userError.message, contains('Open the emulator once or pick the folder again'));
      expect(userError.action, SyncAction.reselectFolder);
    });
  });

  group('buildErrorDetail (item 1)', () {
    test('includes the real exception type and message', () {
      final detail = buildErrorDetail(Exception('disk is full'));
      expect(detail, contains('Exception'));
      expect(detail, contains('disk is full'));
    });

    test('trims to ~300 chars for a very long message', () {
      final longMessage = 'x' * 1000;
      final detail = buildErrorDetail(Exception(longMessage));
      expect(detail.length, lessThanOrEqualTo(301)); // 300 chars + the trailing ellipsis char
    });
  });

  group('SyncLog.detail backward compatibility (item 1)', () {
    test('round-trips through JSON with a detail value', () {
      final log = SyncLog(
        systemId: 'dc',
        status: 'Sync Failed',
        timestamp: DateTime.now(),
        isError: true,
        errorTitle: 'Folder Not Found',
        detail: 'MissingSyncFolderException: dc: folder not found (...)',
      );

      final restored = SyncLog.fromJson(jsonDecode(jsonEncode(log.toJson())));

      expect(restored.detail, log.detail);
      expect(restored.systemId, 'dc');
    });

    test('loads a pre-existing entry with no "detail" key at all (old app version)', () {
      final oldJson = {
        'systemId': 'All',
        'status': 'An unexpected error occurred. Please try again.',
        'timestamp': DateTime.now().toIso8601String(),
        'isError': true,
        'errorTitle': 'Sync Failed',
        'actionLabel': null,
        // no 'detail' key present at all
      };

      final restored = SyncLog.fromJson(oldJson);

      expect(restored.detail, isNull);
      expect(restored.systemId, 'All');
      expect(restored.isError, isTrue);
    });
  });
}
