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
      
      final isRA = lowerId.contains('.ra.') || lowerId.contains('.ra64.') || lowerId.contains('.ra32.');

      // Extract potential packageId from system prefix (e.g. "3ds.azahar" -> "azahar")
      String packageId = lowerId.contains('.') 
          ? lowerId.substring(lowerId.indexOf('.') + 1)
          : lowerId;

      // Check if this matches a known manual mapping (even if not a package format)
      final isManualMapping = (
        packageId == 'azahar' || 
        packageId == 'citra' || 
        packageId == 'citra.desktop' || 
        packageId == 'pcsx2.desktop' ||
        packageId == 'org.azahar_emu.azahar' ||
        packageId.contains('melonds')
      );

      // Determine if this looks like an Android package (has .com. .org. etc)
      final dotCount = '.'.allMatches(lowerId).length;
      final looksLikePackage = dotCount >= 2;

      if (Platform.isAndroid || looksLikePackage || isRA || isManualMapping) {
        // Special case: RetroArch cores
        if (isRA) {
           if (Platform.isAndroid) {
              final raPackages = ['com.retroarch', 'com.retroarch.aarch64', 'com.retroarch.ra32'];
              for (final pkg in raPackages) {
                if (await detector.isEmulatorInstalled(pkg)) {
                  isInstalled = true;
                  break;
                }
              }
           } else {
              // On desktop, we check for the main retroarch command or flatpak
              isInstalled = await detector.isEmulatorInstalled('retroarch');
           }
        } else {
          // Normal package detection or manual mapping
          List<String> candidatePackages = [packageId];
          if (packageId == 'azahar' || packageId == 'citra' || packageId == 'citra.desktop' || packageId == 'org.azahar_emu.azahar' || 
              packageId == 'lime3ds' || packageId == 'lemonade' || packageId == 'mandarine') {
            candidatePackages = [
              'org.azahar_emu.azahar', 
              'org.citra.citra_emu', 
              'com.citra.emu', 
              'org.citra.emu', 
              'org.citra.citra_emu.canary', 
              'org.citra.citra_emu.antimony',
              'io.github.lime3ds.android',
              'org.gamerytb.lemonade.canary',
              'io.github.mandarine3ds.mandarine',
              'io.github.borked3ds.android'
            ];
          } else if (packageId.contains('melonds')) {
            candidatePackages = [
              'me.magnum.melonds',
              'me.arun.melonds',
              'me.magnum.melonds.nightly',
              'me.magnum.melondualds'
            ];
          } else if (packageId == 'pcsx2.desktop') {
            candidatePackages = ['com.pcsx2.pcsx2', 'xyz.aethersx2.android', 'xyz.nethersx2.android'];
          } else if (packageId == 'dolphinemu' || packageId == 'dolphin' || packageId == 'dolphin.desktop') {
            candidatePackages = [
              'org.dolphinemu.dolphinemu',
              'org.dolphinemu.handheld',
              'org.mm.jr',
              'org.mm.j',
              'org.dolphinemu.mmjr',
              'org.dolphinemu.mmjr2',
              'org.dolphinemu.mmjr3',
              'org.dolphin.ishiirukadark',
              'org.dolphinemu.dolphinemu.debug',
              'org.shiiion.primehack'
            ];
          }
              
          for (final pkg in candidatePackages) {
            if (await detector.isEmulatorInstalled(pkg)) {
              isInstalled = true;
              break;
            }
          }
        }
      } 
      
      // If still not detected, try as a desktop emulator if on desktop
      if (!isInstalled && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
        isInstalled = await detector.isEmulatorInstalled(emulator.uniqueId);
      }
      
      if (isInstalled) {
        print('✅ DETECTED: ${systemConfig.system.id} -> ${emulator.name} ($packageId)');
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
