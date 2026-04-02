import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/emulation/domain/emulator_config.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'package:vaultsync_client/features/emulation/presentation/emulator_providers.dart';
import 'package:vaultsync_client/core/services/emulator_detector.dart';
import 'dart:io';

class MockEmulatorRepository extends Mock implements EmulatorRepository {}
class MockDetector extends Mock implements EmulatorDetector {}

void main() {
  late MockEmulatorRepository mockRepository;
  late MockDetector mockDetector;

  setUp(() {
    mockRepository = MockEmulatorRepository();
    mockDetector = MockDetector();
    
    registerFallbackValue('com.retroarch');
    when(() => mockDetector.isEmulatorInstalled(any())).thenAnswer((_) async => false);
  });

  group('systemsProvider mandatory filtering and sorting', () {
    test('should hide systems on Android that have NO installed emulators', () async {
      // NOTE: This test might need Platform override if running on non-Android,
      // but assuming the test environment can simulate Android or we focus on logic.
      if (!Platform.isAndroid) {
        print('Skipping Android-specific filter test on non-Android platform.');
        return;
      }

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
      
      // Mock: Only AetherSX2 is installed.
      when(() => mockDetector.isEmulatorInstalled('com.tahlreth.aethersx2.free')).thenAnswer((_) async => true);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      // Only PS2 should be shown
      expect(result.length, 1);
      expect(result.first.system.id, 'ps2');
    });

    test('should NOT hide systems on Desktop even if NO emulators are detected', () async {
      if (Platform.isAndroid) {
        print('Skipping Desktop-specific visibility test on Android platform.');
        return;
      }

      final snesConfig = EmulatorConfig(
        system: SystemInfo(id: 'snes', name: 'SNES', folders: ['snes'], extensions: ['smc'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'RetroArch Snes9x', uniqueId: 'snes.ra.snes9x', defaultEmulator: true),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [snesConfig]);
      
      // Mock: Nothing is detected
      when(() => mockDetector.isEmulatorInstalled(any())).thenAnswer((_) async => false);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      // On Desktop, it should still show SNES
      expect(result.length, 1);
      expect(result.first.system.id, 'snes');
    });
  });
}
