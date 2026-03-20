import 'dart:io';

class PlatformUtils {
  static bool isEmulatorSupported(String uniqueId) {
    final lowerId = uniqueId.toLowerCase();
    
    // 1. RetroArch cores are cross-platform
    if (lowerId.contains('.ra.') || lowerId.contains('.ra64.') || lowerId.contains('.ra32.')) {
      return true;
    }
    
    // 2. Desktop-explicit emulators
    if (lowerId.endsWith('.desktop')) {
      return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    }
    
    // 3. Android/iOS package names (e.g. .com., .org., .it.) are mobile-only
    // unless they specifically have the .desktop suffix (handled above).
    final isPackageFormat = lowerId.contains('.com.') || 
                            lowerId.contains('.org.') || 
                            lowerId.contains('.net.') ||
                            lowerId.contains('.it.') ||
                            lowerId.contains('.come.'); // seen in some of our configs
                            
    if (isPackageFormat) {
      return Platform.isAndroid || Platform.isIOS;
    }
    
    // 4. Default fallback:
    // On Android/iOS, assume it might work.
    // On Desktop, if it didn't match .desktop, assume it's mobile-only.
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return false;
    }
    
    return true;
  }
}
