import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/core/services/emulator_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.vaultsync.app/launcher');

  group('AndroidEmulatorDetector', () {
    late AndroidEmulatorDetector detector;

    setUp(() {
      detector = AndroidEmulatorDetector();
    });

    test('isEmulatorInstalled returns true when package is found', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        if (methodCall.method == 'isPackageInstalled') {
          if (methodCall.arguments['packageName'] == 'com.citra.emu') {
            return true;
          }
        }
        return false;
      });

      final result = await detector.isEmulatorInstalled('com.citra.emu');
      expect(result, isTrue);
    });

    test('isEmulatorInstalled returns false when package is not found', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        if (methodCall.method == 'isPackageInstalled') {
          return false;
        }
        return null;
      });

      final result = await detector.isEmulatorInstalled('com.unknown.emu');
      expect(result, isFalse);
    });

    test('isEmulatorInstalled returns false on PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        throw PlatformException(code: 'ERROR', message: 'Something went wrong');
      });

      final result = await detector.isEmulatorInstalled('com.citra.emu');
      expect(result, isFalse);
    });
  });

  group('LinuxEmulatorDetector', () {
    late LinuxEmulatorDetector detector;

    setUp(() {
      detector = LinuxEmulatorDetector();
    });

    test('isEmulatorInstalled returns false for non-existent absolute path', () async {
      final result = await detector.isEmulatorInstalled('/non/existent/path');
      expect(result, isFalse);
    });
  });

  group('WindowsEmulatorDetector', () {
    late WindowsEmulatorDetector detector;

    setUp(() {
      detector = WindowsEmulatorDetector();
    });

    test('isEmulatorInstalled returns false for non-existent path', () async {
      final result = await detector.isEmulatorInstalled('C:\\NonExistent\\emu.exe');
      expect(result, isFalse);
    });
  });
}
