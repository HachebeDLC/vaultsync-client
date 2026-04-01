import 'dart:io';
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
      bool isInstalled = false;
      final lowerId = emulator.uniqueId.toLowerCase();
      
      // Determine if this looks like an Android package (has .com. .org. etc)
      // or if we are explicitly on Android and it's a RetroArch core.
      final isRA = lowerId.contains('.ra.') || lowerId.contains('.ra64.') || lowerId.contains('.ra32.');
      final isPackageFormat = lowerId.contains('.com.') || 
                            lowerId.contains('.org.') || 
                            lowerId.contains('.net.') ||
                            lowerId.contains('.it.') ||
                            lowerId.contains('.come.');

      if (Platform.isAndroid || isPackageFormat || isRA) {
        // Special case: RetroArch cores (Android specific detection)
        if (isRA) {
           final raPackages = ['com.retroarch', 'com.retroarch.aarch64', 'com.retroarch.ra32'];
           for (final pkg in raPackages) {
             if (await detector.isEmulatorInstalled(pkg)) {
               isInstalled = true;
               break;
             }
           }
        } else {
          // Normal package detection: strip the system prefix (e.g. "ps2.com.tahlreth.aethersx2" -> "com.tahlreth.aethersx2")
          String packageId = lowerId.contains('.') 
              ? lowerId.substring(lowerId.indexOf('.') + 1)
              : lowerId;
          
          // Manual mappings
          if (packageId == 'azahar') packageId = 'org.citra.citra_emu';
          if (packageId == 'citra') packageId = 'com.citra.emu';
          if (packageId == 'citra.desktop') packageId = 'com.citra.emu';
          if (packageId == 'pcsx2.desktop') packageId = 'com.pcsx2.pcsx2';
              
          isInstalled = await detector.isEmulatorInstalled(packageId);
        }
      } 
      
      // If still not detected, try as a desktop emulator if on desktop
      if (!isInstalled && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
        isInstalled = await detector.isEmulatorInstalled(emulator.uniqueId);
      }
      
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
