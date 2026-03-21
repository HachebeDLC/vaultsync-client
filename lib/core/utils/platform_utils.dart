import 'dart:io';

class PlatformUtils {
  // A curated list of the best-in-class RetroArch cores, aligned with EmuDeck's choices.
  // This prevents the desktop UI from being flooded with 40+ variants of SNES/Genesis cores.
  static const _desktopAllowedRaCores = {
    'snes9x', 'mesen', 'genesis_plus_gx', 'picodrive', 'puae', 'vice', 
    'caprice32', 'stella', 'handy', 'prboom', 'dosbox_pure', 'easyrpg', 
    'fbneo', 'freeintv', 'mame2003_plus', 'mame2010', 'mame', 
    'neko_project_ii_kai', 'mednafen_pce_fast', 'mednafen_neopop', 
    'citra', 'mupen64plus_next', 'melonds', 'melondsds', 'sameboy', 
    'gambatte', 'mgba', 'nestopia', 'bsnes_hd_beta', 'mednafen_vb', 
    'opera', 'pico8', 'mednafen_saturn', 'kronos', 'yabause', 
    'px68k', 'fuse', 'mednafen_psx_hw', 'swanstation', 'ppsspp', 'mednafen_wswan'
  };

  static bool isEmulatorSupported(String uniqueId) {
    final lowerId = uniqueId.toLowerCase();
    final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    
    // 1. RetroArch cores
    if (lowerId.contains('.ra.') || lowerId.contains('.ra64.') || lowerId.contains('.ra32.')) {
      if (isDesktop) {
        // Hide Android 32-bit and 64-bit specific packages on Desktop
        if (lowerId.contains('.ra64.') || lowerId.contains('.ra32.')) {
          return false;
        }
        
        // Filter down to the curated EmuDeck/Standard list so the UI isn't cluttered
        final coreId = lowerId.split('.').last;
        if (!_desktopAllowedRaCores.contains(coreId) && !_desktopAllowedRaCores.any((c) => lowerId.endsWith(c))) {
          return false;
        }
      }
      return true;
    }
    
    // 2. Desktop-explicit emulators
    if (lowerId.endsWith('.desktop')) {
      return isDesktop;
    }
    
    // 3. Android/iOS package names (e.g. .com., .org., .it.) are mobile-only
    final isPackageFormat = lowerId.contains('.com.') || 
                            lowerId.contains('.org.') || 
                            lowerId.contains('.net.') ||
                            lowerId.contains('.it.') ||
                            lowerId.contains('.come.');
                            
    if (isPackageFormat) {
      return Platform.isAndroid || Platform.isIOS;
    }
    
    // 4. Default fallback
    if (isDesktop) {
      return false;
    }
    
    return true;
  }
}
