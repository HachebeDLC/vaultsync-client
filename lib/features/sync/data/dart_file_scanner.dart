import 'dart:io';

class DartFileScanner {
  static const _syncEverythingSids = {'switch', 'eden'};
  
  static const _saveExtensions = {
    "srm", "state", "auto", "mcd", "mcr", "ps2", "gci", "raw",
    "dsv", "dss", "vms", "vmu", "eep", "sra", "fla", "mpk",
    "bcr", "ngf", "ngs", "sav", "png", "bak", "vfs"
  };
  
  static const _hardcodedIgnores = {
    "cache", "shaders", "resourcepack", "load",
    "log", "logs", "temp", "tmp", "bios", "covers",
    "textures", "custom_textures", "game"
  };

  static bool _shouldSyncFile(String sid, String relPath, String fileName, String rootPath) {
    if (fileName.startsWith(".")) return false;
    
    if (_syncEverythingSids.contains(sid)) return true;
    
    if (sid == "psp" || sid == "ppsspp") {
      final lowerRel = relPath.toLowerCase();
      final lowerRoot = rootPath.toLowerCase();
      
      // If the user pointed directly to the save folder, sync everything inside
      if (lowerRoot.contains("savedata") || lowerRoot.contains("ppsspp_state")) return true;
      
      // Otherwise, only sync files that reside in the correct subfolders
      return lowerRel.contains("savedata/") || lowerRel.contains("ppsspp_state/");
    }
    
    if (sid == "wii") {
      return relPath.toLowerCase().contains("title/0001000");
    }
    
    if (sid == "3ds" || sid == "citra" || sid == "azahar") {
      return relPath.toLowerCase().contains("title/00040000");
    }
    
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : "";
    return ext.isNotEmpty && _saveExtensions.contains(ext);
  }

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
          final fileName = entity.path.split('/').last;
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
            if (_shouldSyncFile(sid, relPath, fileName, rootPath)) {
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
      } catch (_) {}
    }

    await walk(rootDir, "", 0);
    return results;
  }
}
