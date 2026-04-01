import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/emulation/domain/emulator_config.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'package:vaultsync_client/features/emulation/presentation/emulator_providers.dart';
import 'package:vaultsync_client/core/services/emulator_detector.dart';

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
      when(() => mockDetector.isEmulatorInstalled('com.retroarch')).thenAnswer((_) async => false);

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

    test('should detect MelonDS via multiple package candidates', () async {
      final systemConfig = EmulatorConfig(
        system: SystemInfo(id: 'nds', name: 'DS', folders: ['nds'], extensions: ['nds'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'MelonDS', uniqueId: 'nds.me.magnum.melonds', defaultEmulator: true),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [systemConfig]);
      
      // Mock: MelonDS is installed
      when(() => mockDetector.isEmulatorInstalled('me.magnum.melonds')).thenAnswer((_) async => true);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      expect(result.length, 1);
      expect(result.first.emulators.first.isInstalled, isTrue);
    });

    test('should detect Azahar/Citra via multiple package candidates', () async {
      final systemConfig = EmulatorConfig(
        system: SystemInfo(id: '3ds', name: '3DS', folders: ['3ds'], extensions: ['3ds'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'Azahar', uniqueId: '3ds.azahar', defaultEmulator: true),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [systemConfig]);
      
      // Mock: Azahar is installed using one of the common Citra package names
      when(() => mockDetector.isEmulatorInstalled('org.citra.citra_emu')).thenAnswer((_) async => true);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      expect(result.length, 1);
      expect(result.first.emulators.first.isInstalled, isTrue);
    });

    test('should detect RetroArch cores if RetroArch package is installed', () async {
      final systemConfig = EmulatorConfig(
        system: SystemInfo(id: 'snes', name: 'SNES', folders: ['snes'], extensions: ['smc'], ignoredFolders: []),
        emulators: [
          EmulatorInfo(name: 'RetroArch Snes9x', uniqueId: 'snes.ra.snes9x', defaultEmulator: true),
        ],
      );

      when(() => mockRepository.loadSystems()).thenAnswer((_) async => [systemConfig]);
      
      // Mock: RetroArch is installed
      when(() => mockDetector.isEmulatorInstalled('com.retroarch.aarch64')).thenAnswer((_) async => true);

      final container = ProviderContainer(
        overrides: [
          emulatorRepositoryProvider.overrideWith((ref) => mockRepository),
          emulatorDetectorProvider.overrideWith((ref) => mockDetector),
        ],
      );

      final result = await container.read(systemsProvider.future);
      
      expect(result.length, 1);
      expect(result.first.emulators.first.isInstalled, isTrue);
    });

    test('should hide systems that have NO installed emulators', () async {
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
      
      // Mock: Only AetherSX2 is installed. RetroArch is NOT.
      when(() => mockDetector.isEmulatorInstalled('com.tahlreth.aethersx2.free')).thenAnswer((_) async => true);
      when(() => mockDetector.isEmulatorInstalled('com.retroarch')).thenAnswer((_) async => false);
      when(() => mockDetector.isEmulatorInstalled('com.retroarch.aarch64')).thenAnswer((_) async => false);
      when(() => mockDetector.isEmulatorInstalled('com.retroarch.ra32')).thenAnswer((_) async => false);

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
  });
}
