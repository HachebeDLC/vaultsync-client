import 'dart:developer' as developer;
import 'dart:io';

/// Utility for recursively scanning the local filesystem for emulator-specific save files.
class DartFileScanner {
  static const _syncEverythingSids = {'switch', 'eden'};
  
  static const _saveExtensions = {
    "srm", "state", "auto", "mcd", "mcr", "ps2", "gci", "raw",
    "dsv", "dss", "vms", "vmu", "eep", "sra", "fla", "mpk",
    "bcr", "ngf", "ngs", "sav", "png", "bak", "vfs",
    "nv", "rtc", "mcx", "mc", "dsx"
  };
  
  static const _hardcodedIgnores = {
    "cache", "shaders", "resourcepack", "load",
    "log", "logs", "temp", "tmp", "bios", "covers",
    "textures", "custom_textures", "game"
  };

  static bool _shouldSyncFile(String sid, String relPath, String fileName) {
    if (fileName.startsWith(".")) return false;
    
    if (_syncEverythingSids.contains(sid)) return true;
    
    if (sid == "psp" || sid == "ppsspp") {
      final lower = relPath.toLowerCase();
      // Restore flexibility: sync subfolders and files sitting at the root.
      // Global noise filters (textures, game, etc.) still apply via walk logic.
      return lower.contains("savedata/") || lower.contains("ppsspp_state/") || !lower.contains("/");
    }
    
    if (sid == "wii") {
      // Matches 00010000 (disc), 00010001 (channels), 00010002 (system), 00010004 (WiiWare), 00010005 (DLC)
      return relPath.toLowerCase().contains("title/0001000");
    }
    
    if (sid == "3ds" || sid == "citra" || sid == "azahar") {
      return relPath.toLowerCase().contains("title/00040000");
    }
    
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : "";
    return ext.isNotEmpty && _saveExtensions.contains(ext);
  }

  /// Recursively walks the directory at `rootPath` and returns a metadata list of 
  /// files that match the synchronization rules for `systemId`.
  static Future<List<Map<String, dynamic>>> scanRecursive(String rootPath, String systemId, List<String> ignoredFolders) async {
    final sid = systemId.toLowerCase();
    final results = <Map<String, dynamic>>[];
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) return results;

    final ignoreSet = ignoredFolders.map((e) => e.toLowerCase()).toSet();
    final isSwitch = sid == "switch" || sid == "eden";
    final alreadyInZone = isSwitch && rootPath.toLowerCase().contains("nand/user/save");

    Future<void> walk(Directory dir, String currentRelPath, int depth) async {
      if (depth > 15) return;
      try {
        final list = await dir.list().toList();
        for (final entity in list) {
          final fileName = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          final relPath = currentRelPath.isEmpty ? fileName : '$currentRelPath/$fileName';
          
          if (_hardcodedIgnores.contains(fileName.toLowerCase()) || ignoreSet.contains(relPath.toLowerCase())) {
            continue;
          }

          if (isSwitch && !alreadyInZone) {
            final lowerRelPath = relPath.toLowerCase();
            final inSavePath = lowerRelPath.contains("nand/user/save");
            if (!inSavePath && !lowerRelPath.startsWith("nand") && lowerRelPath != "nand") {
              continue;
            }
          }

          if (entity is Directory) {
            results.add({
              'name': fileName,
              'relPath': relPath,
              'isDirectory': true,
              'uri': entity.path,
            });
            await walk(entity, relPath, depth + 1);
          } else if (entity is File) {
            if (_shouldSyncFile(sid, relPath, fileName)) {
              final stat = await entity.stat();
              results.add({
                'name': fileName,
                'relPath': relPath,
                'isDirectory': false,
                'size': stat.size,
                'lastModified': stat.modified.millisecondsSinceEpoch,
                'uri': entity.path,
              });
            }
          }
        }
      } catch (e) {
        developer.log('SCAN: Skipped ${dir.path} due to error', name: 'VaultSync', level: 900, error: e);
      }
    }

    await walk(rootDir, "", 0);
    return results;
  }
}
