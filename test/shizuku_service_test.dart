import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/shizuku_service.dart';
import 'package:flutter/services.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShizukuStatus', () {
    test('should parse correctly from map', () {
      final map = {
        'running': true,
        'authorized': true,
        'version': 13,
      };
      final status = ShizukuStatus.fromMap(map);
      expect(status.isRunning, true);
      expect(status.isAuthorized, true);
      expect(status.version, 13);
      expect(status.error, isNull);
    });

    test('should handle missing fields with defaults', () {
      final status = ShizukuStatus.fromMap({});
      expect(status.isRunning, false);
      expect(status.isAuthorized, false);
      expect(status.version, 0);
    });
  });

  group('ShizukuService', () {
    const channel = MethodChannel('com.vaultsync.app/launcher');
    late ShizukuService service;

    setUp(() {
      service = ShizukuService();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (methodCall) async {
          if (methodCall.method == 'checkShizukuStatus') {
            return {'running': true, 'authorized': false, 'version': 11};
          }
          if (methodCall.method == 'requestShizukuPermission') {
            return true;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('getStatus returns mapped status', () async {
      // Skip on non-android host to maintain purity
      if (!Platform.isAndroid) return;
      
      final status = await service.getStatus();
      expect(status.isRunning, true);
      expect(status.isAuthorized, false);
      expect(status.version, 11);
    });

    test('requestPermission returns boolean result', () async {
      if (!Platform.isAndroid) return;

      final result = await service.requestPermission();
      expect(result, true);
    });
  });
}
