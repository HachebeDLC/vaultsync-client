import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';

void main() {
  late SyncPathResolver resolver;

  setUp(() {
    resolver = SyncPathResolver();
  });

  group('SyncPathResolver - RetroArch Integration', () {
    test('getCloudRelPath should route .srm files to saves/ when anchor is missing', () {
      final result = resolver.getCloudRelPath('RetroArch', 'Pokemon.srm');
      expect(result, 'saves/Pokemon.srm');
    });

    test('getCloudRelPath should route .state files to states/ when anchor is missing', () {
      final result = resolver.getCloudRelPath('RetroArch', 'Pokemon.state');
      expect(result, 'states/Pokemon.state');
    });

    test('getCloudRelPath should preserve explicit saves/ anchor', () {
      final result = resolver.getCloudRelPath('RetroArch', 'saves/GBA/Pokemon.srm');
      expect(result, 'saves/GBA/Pokemon.srm');
    });

    test('getCloudRelPath should preserve explicit states/ anchor', () {
      final result = resolver.getCloudRelPath('RetroArch', 'states/GBA/Pokemon.state');
      expect(result, 'states/GBA/Pokemon.state');
    });

    test('getCloudRelPath should return empty for non-save/state files in root', () {
      final result = resolver.getCloudRelPath('RetroArch', 'retroarch.cfg');
      expect(result, '');
    });

    test('getLocalRelPath should strip saves/ prefix when local root is a subfolder (no anchors)', () {
      // simulate a local sync root that is just the saves folder (no saves/ or states/ folders inside)
      final lastScan = [
        {'relPath': 'Pokemon.srm', 'isDirectory': false}
      ];
      
      final result = resolver.getLocalRelPath(
        'RetroArch', 
        'RetroArch/saves/Pokemon.srm', 
        {}, 
        lastScan
      );
      
      expect(result, 'Pokemon.srm');
    });

    test('getLocalRelPath should strip states/ prefix when local root is a subfolder', () {
      final lastScan = [
        {'relPath': 'Pokemon.state', 'isDirectory': false}
      ];
      
      final result = resolver.getLocalRelPath(
        'RetroArch', 
        'RetroArch/states/Pokemon.state', 
        {}, 
        lastScan
      );
      
      expect(result, 'Pokemon.state');
    });

    test('getLocalRelPath should PRESERVE saves/ prefix when local root has anchors (EmuDeck style)', () {
      final lastScan = [
        {'relPath': 'saves/Pokemon.srm', 'isDirectory': false},
        {'relPath': 'states/Pokemon.state', 'isDirectory': false}
      ];
      
      final result = resolver.getLocalRelPath(
        'RetroArch', 
        'RetroArch/saves/Pokemon.srm', 
        {}, 
        lastScan
      );
      
      expect(result, 'saves/Pokemon.srm');
    });
  });
}
