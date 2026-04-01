import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/emulation/domain/emulator_config.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'package:vaultsync_client/features/emulation/presentation/emulator_providers.dart';
import 'package:vaultsync_client/core/services/emulator_detector.dart';

class MockEmulatorRepository extends Mock implements EmulatorRepository {}
class MockEmulatorDetector extends Mock implements EmulatorDetector {}

void main() {
  late MockEmulatorRepository mockRepository;
  late MockEmulatorDetector mockDetector;

  setUp(() {
    mockRepository = MockEmulatorRepository();
    mockDetector = MockEmulatorDetector();
    
    when(() => mockDetector.isEmulatorInstalled(any())).thenAnswer((_) async => false);
  });

  group('systemsProvider filtering and sorting', () {
    test('should prioritize installed standalone emulators over RetroArch cores', () async {
      final systemConfig = EmulatorConfig(
        system: SystemInfo(id: 'snes', name: 'SNES', folders: ['snes'], extensions: ['smc'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'RetroArch Snes9x', uniqueId: 'snes.ra.snes9x', defaultEmulator: true),
          EmulatorInfo(name: 'Snes9x EX+', uniqueId: 'snes.com.explusplus.snes9x', defaultEmulator: false),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [systemConfig]);
      
      // Mock: Only standalone Snes9x EX+ is installed
      when(() => mockDetector.isEmulatorInstalled('com.explusplus.snes9x')).thenAnswer((_) async => true);
      when(() => mockDetector.isEmulatorInstalled('ra.snes9x')).thenAnswer((_) async => false);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      expect(result.length, 1);
      final emulators = result.first.emulators;
      
      // Snes9x EX+ should be first because it is installed and standalone
      expect(emulators[0].name, 'Snes9x EX+');
      expect(emulators[0].isInstalled, isTrue);
      
      expect(emulators[1].name, 'RetroArch Snes9x');
      expect(emulators[1].isInstalled, isFalse);
    });

    test('should filter systems when showInstalledOnly is true', () async {
      final snesConfig = EmulatorConfig(
        system: SystemInfo(id: 'snes', name: 'SNES', folders: ['snes'], extensions: ['smc'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'RetroArch Snes9x', uniqueId: 'snes.ra.snes9x', defaultEmulator: true),
        ],
      );
      
      final ps2Config = EmulatorConfig(
        system: SystemInfo(id: 'ps2', name: 'PS2', folders: ['ps2'], extensions: ['iso'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'AetherSX2', uniqueId: 'ps2.com.tahlreth.aethersx2.free', defaultEmulator: true),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [snesConfig, ps2Config]);
      
      // Mock: Only AetherSX2 is installed
      when(() => mockDetector.isEmulatorInstalled('com.tahlreth.aethersx2.free')).thenAnswer((_) async => true);
      when(() => mockDetector.isEmulatorInstalled('ra.snes9x')).thenAnswer((_) async => false);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
          showInstalledOnlyProvider.overrideWith((ref) => true),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      // Only PS2 should be shown because it has an installed emulator
      expect(result.length, 1);
      expect(result.first.system.id, 'ps2');
    });
  });
}
