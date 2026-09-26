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

    test('redacts a Bearer token from the message', () {
      final detail = buildErrorDetail(
          Exception('HTTP 401: Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc-def'));
      expect(detail, isNot(contains('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9')));
      expect(detail, contains('Bearer [REDACTED]'));
    });

    test('redacts an api_key query-style value from the message', () {
      final detail =
          buildErrorDetail(Exception('failed GET https://romm.local/api?api_key=sk-abcdef123456'));
      expect(detail, isNot(contains('sk-abcdef123456')));
      expect(detail, contains('[REDACTED]'));
    });

    test('redacts a JSON-ish password field from the message', () {
      final detail =
          buildErrorDetail(Exception('server said: {"password": "hunter2", "ok": false}'));
      expect(detail, isNot(contains('hunter2')));
    });

    test('does not redact ordinary text that merely contains "key" as a substring', () {
      final detail = buildErrorDetail(Exception('missing keyboard focus node'));
      expect(detail, contains('missing keyboard focus node'));
      expect(detail, isNot(contains('REDACTED')));
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
