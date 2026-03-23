import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'dart:io';

class MockEmulatorRepository extends Mock implements EmulatorRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late SystemPathService service;
  late MockEmulatorRepository mockRepo;

  setUp(() {
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
      expect(path, anyOf(contains('memcards'), contains('Documents')));
    }
  });
}
