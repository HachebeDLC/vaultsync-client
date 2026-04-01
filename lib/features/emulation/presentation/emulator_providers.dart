import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/emulator_repository.dart';
import '../domain/emulator_config.dart';
import '../../../core/services/emulator_detector.dart';

final systemsProvider = FutureProvider<List<EmulatorConfig>>((ref) async {
  final repository = ref.watch(emulatorRepositoryProvider);
  final detector = ref.watch(emulatorDetectorProvider);

  final allSystems = await repository.loadSystems();
  List<EmulatorConfig> processedSystems = [];

  for (var systemConfig in allSystems) {
    List<EmulatorInfo> detectedEmulators = [];
    
    // 1. Detect which emulators are installed
    for (var emulator in systemConfig.emulators) {
      // For Android, unique_id like "switch.dev.eden.eden_emulator" needs the package part
      final packageId = emulator.uniqueId.contains('.') 
          ? emulator.uniqueId.substring(emulator.uniqueId.indexOf('.') + 1)
          : emulator.uniqueId;
          
      final isInstalled = await detector.isEmulatorInstalled(packageId);
      detectedEmulators.add(emulator.copyWith(isInstalled: isInstalled));
    }

    // 2. Sort emulators: Installed Standalone > Installed RetroArch > Uninstalled
    detectedEmulators.sort((a, b) {
      if (a.isInstalled != b.isInstalled) {
        return a.isInstalled ? -1 : 1;
      }
      
      // Both have same installation status, sort by type (Standalone vs RetroArch)
      final aIsRA = a.uniqueId.contains('.ra.') || a.uniqueId.contains('.ra64.') || a.uniqueId.contains('.ra32.');
      final bIsRA = b.uniqueId.contains('.ra.') || b.uniqueId.contains('.ra64.') || b.uniqueId.contains('.ra32.');
      
      if (aIsRA != bIsRA) {
        return aIsRA ? 1 : -1; // Standalone (-1) before RetroArch (1)
      }
      
      // Finally, default emulator first
      if (a.defaultEmulator != b.defaultEmulator) {
        return a.defaultEmulator ? -1 : 1;
      }
      
      return 0;
    });

    final processedSystem = systemConfig.copyWith(emulators: detectedEmulators);

    // 3. Filter systems: Only show systems that have at least one emulator installed
    if (detectedEmulators.any((e) => e.isInstalled)) {
      processedSystems.add(processedSystem);
    }
  }

  return processedSystems;
});
