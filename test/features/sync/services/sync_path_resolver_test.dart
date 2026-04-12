import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';

void main() {
  late SyncPathResolver resolver;

  setUp(() {
    resolver = SyncPathResolver();
  });

  group('SyncPathResolver - getCloudRelPath with Probed Metadata', () {
    test('should prioritize probed titleId for Switch and include filename', () {
      final result = resolver.getCloudRelPath(
        'switch',
        'nand/user/save/000/0100ABCD12345678/0.bin',
        probedMetadata: {'titleId': '0100FFFFFFFFFFFF'},
      );
      expect(result, '0100FFFFFFFFFFFF/0.bin');
    });

    test('should fallback to path titleId for Switch if no probed data', () {
      final result = resolver.getCloudRelPath(
        'switch',
        'A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4/0100ABCD12345678/0.bin',
      );
      expect(result, '0100ABCD12345678/0.bin');
    });

    test('should use probed gameId for GameCube and keep extension', () {
      final result = resolver.getCloudRelPath(
        'gc',
        'GALE01.gci',
        probedMetadata: {'gameId': 'GZLE', 'makerCode': '01'},
      );
      expect(result, 'GZLE.gci');
    });

    test('should use probed gameId for PSP', () {
      final result = resolver.getCloudRelPath(
        'psp',
        'UCUS98765/DATA.BIN',
        probedMetadata: {'gameId': 'UCUS98631'},
      );
      expect(result, 'SAVEDATA/UCUS98631');
    });
  });
}
