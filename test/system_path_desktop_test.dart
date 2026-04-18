import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'dart:io';

class MockEmulatorRepository extends Mock implements EmulatorRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SystemPathService service;
  late MockEmulatorRepository mockRepo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockRepo = MockEmulatorRepository();
    service = SystemPathService(mockRepo);
  });

  test('SystemPathService should suggest desktop paths on non-android', () async {
    print('DEBUG: OS is ${Platform.operatingSystem}');
    // This test will run on the host (Linux/Windows/macOS)
    if (!Platform.isAndroid) {
      final path = await service.suggestSavePathById('ps2');
      print('DEBUG: Suggested path for ps2: $path');
      expect(path, contains('PCSX2'));
    }
  });

  group('getSystemPath Switch walk-down auto-correction', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vaultsync_switch_path_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('walks pkg-dir path into /files and persists the fix', () async {
      final pkg = Directory(p.join(tmp.path, 'pkg'));
      await Directory(p.join(pkg.path, 'files', 'nand', 'user', 'save'))
          .create(recursive: true);

      SharedPreferences.setMockInitialValues(
          {'system_path_switch': pkg.path});
      service = SystemPathService(mockRepo);

      final resolved = await service.getSystemPath('switch');
      expect(resolved, p.join(pkg.path, 'files'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('system_path_switch'),
          p.join(pkg.path, 'files'));
    });

    test('leaves path alone when it is already at the files root', () async {
      final filesRoot = Directory(p.join(tmp.path, 'pkg', 'files'));
      await Directory(p.join(filesRoot.path, 'nand', 'user', 'save'))
          .create(recursive: true);

      SharedPreferences.setMockInitialValues(
          {'system_path_switch': filesRoot.path});
      service = SystemPathService(mockRepo);

      final resolved = await service.getSystemPath('switch');
      expect(resolved, filesRoot.path);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('system_path_switch'), filesRoot.path);
    });

    test('leaves SAF (content://) paths untouched', () async {
      const safUri =
          'content://com.android.externalstorage.documents/tree/primary%3AEmu';
      SharedPreferences.setMockInitialValues({'system_path_switch': safUri});
      service = SystemPathService(mockRepo);

      final resolved = await service.getSystemPath('switch');
      expect(resolved, safUri);
    });

    test('still trims overly-deep /nand/user/save path', () async {
      final deep = p.join(tmp.path, 'pkg', 'files', 'nand', 'user', 'save');
      await Directory(deep).create(recursive: true);

      SharedPreferences.setMockInitialValues({'system_path_switch': deep});
      service = SystemPathService(mockRepo);

      final resolved = await service.getSystemPath('switch');
      expect(resolved, p.join(tmp.path, 'pkg', 'files'));
    });
  });
}
