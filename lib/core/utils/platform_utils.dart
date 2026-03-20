import 'dart:io';

class PlatformUtils {
  static bool isEmulatorSupported(String uniqueId) {
    final lowerId = uniqueId.toLowerCase();
    
    // RetroArch cores are considered cross-platform for VaultSync's mapping logic
    if (lowerId.contains('.ra.') || lowerId.contains('.ra64.') || lowerId.contains('.ra32.')) {
      return true;
    }
    
    // Desktop specific emulators
    if (lowerId.endsWith('.desktop')) {
      return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    }
    
    // Android/iOS specific emulators (NetherSX2, etc.)
    return Platform.isAndroid || Platform.isIOS;
  }
}
