class SyncPathResolver {
  String getCloudRelPath(String systemId, String localRelPath) {
    final sid = systemId.toLowerCase();
    final parts = localRelPath.split('/');
    
    // 1. Switch / Eden Logic (Flattened)
    if (sid == 'switch' || sid == 'eden') {
      final titleIdx = parts.indexWhere((p) => RegExp(r'^0100[0-9A-Fa-f]{12}$').hasMatch(p));
      if (titleIdx != -1) return parts.sublist(titleIdx).join('/');
      return '';
    } 
    
    // 2. PS2 / DuckStation Logic (Anchor on memcards)
    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
      final anchorIdx = parts.indexWhere((p) => ['memcards', 'memcard', 'sstates', 'gamesettings'].contains(p.toLowerCase()));
      if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
      return '';
    }

    // 3. Wii Logic (Surgical Flattening)
    if (sid == 'wii') {
      final anchorIdx = parts.indexOf('00010000');
      if (anchorIdx != -1 && anchorIdx < parts.length - 1) {
        return parts.sublist(anchorIdx + 1).join('/'); // Produces 'GameID/data/...'
      }
      return ''; // Strictly ignore everything NOT in the game saves folder
    }

    // 4. GameCube Logic (Preserve GC/ prefix)
    if (sid == 'gc') {
      final gcIdx = parts.indexWhere((p) => p.toLowerCase() == 'gc');
      if (gcIdx != -1) {
        return parts.sublist(gcIdx).join('/'); // Produces 'GC/...'
      }
      return ''; // Strictly ignore everything NOT in the GC folder
    }

    // 5. Dolphin (Generic) - Handle both if the system name is just 'dolphin'
    if (sid == 'dolphin') {
      if (localRelPath.toLowerCase().contains('/wii/title/00010000/')) {
         final idx = parts.indexOf('00010000');
         return 'Wii/${parts.sublist(idx + 1).join('/')}';
      }
      if (localRelPath.toLowerCase().contains('/gc/')) {
         final idx = parts.indexWhere((p) => p.toLowerCase() == 'gc');
         return parts.sublist(idx).join('/');
      }
      return '';
    }

    // 6. 3DS (Azahar / Citra) Logic
    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       final titleIdx = parts.indexOf('00040000');
       if (titleIdx != -1 && titleIdx < parts.length - 1) {
           return 'saves/${parts.sublist(titleIdx + 1).join('/')}';
       }
       final anchorIdx = parts.indexWhere((p) => ['nand', 'sdmc', 'sysdata'].contains(p.toLowerCase()));
       if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
       return '';
    }

    // 7. PSP (PPSSPP) Logic
    if (sid == 'psp' || sid == 'ppsspp') {
       final anchorIdx = parts.indexWhere((p) => ['savedata', 'ppsspp_state'].contains(p.toLowerCase()));
       if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
    }

    return localRelPath;
  }

  String getLocalRelPath(String systemId, String cloudRelPath, Map<String, dynamic> localFiles, List<dynamic> lastScanList) {
    if (localFiles.containsKey(cloudRelPath)) return localFiles[cloudRelPath]['originalRelPath'] ?? cloudRelPath;
    
    final sid = systemId.toLowerCase();
    final hasFilesDir = localFiles.values.any((f) => (f['relPath'] as String).startsWith('files/'));

    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
       final prefix = hasFilesDir ? 'files/' : '';
       if (!cloudRelPath.startsWith('memcards') && !cloudRelPath.startsWith('sstates')) {
          return '${prefix}memcards/$cloudRelPath';
       }
       return '$prefix$cloudRelPath';
    }

    if (sid == 'wii') {
       final prefix = hasFilesDir ? 'files/' : '';
       return '${prefix}Wii/title/00010000/$cloudRelPath';
    }

    if (sid == 'gc') {
       final prefix = hasFilesDir ? 'files/' : '';
       return '$prefix$cloudRelPath';
    }

    if (sid == 'dolphin') {
       final prefix = hasFilesDir ? 'files/' : '';
       return '$prefix$cloudRelPath';
    }

    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       if (cloudRelPath.startsWith('saves/')) {
          final suffix = cloudRelPath.substring(6);
          final prefix = hasFilesDir ? 'files/' : '';
          
          // Probing: Find real Console ID and SD ID from scan list
          String consoleId = '00000000000000000000000000000000';
          String sdId = '00000000000000000000000000000000';
          final idRegex = RegExp(r'^[0-9A-Fa-f]{32}$');

          for (final f in lastScanList) {
             final path = f['relPath'] as String;
             final parts = path.split('/');
             final idx = parts.indexOf('Nintendo 3DS');
             if (idx != -1 && idx + 2 < parts.length) {
                final cid = parts[idx + 1];
                final sidPart = parts[idx + 2];
                if (idRegex.hasMatch(cid) && idRegex.hasMatch(sidPart)) {
                   consoleId = cid;
                   sdId = sidPart;
                   break;
                }
             }
          }

          return '${prefix}sdmc/Nintendo 3DS/$consoleId/$sdId/title/00040000/$suffix';
       }
       return cloudRelPath;
    }

    if (sid == 'psp' || sid == 'ppsspp') {
       if (!cloudRelPath.startsWith('SAVEDATA') && !cloudRelPath.startsWith('PPSSPP_STATE')) {
          return 'SAVEDATA/$cloudRelPath';
       }
       return cloudRelPath;
    }

    if (sid == 'switch' || sid == 'eden') {
       final cloudTitleId = cloudRelPath.split('/').first;
       
       // 1. Try to find where this TitleID ALREADY lives locally
       for (final f in localFiles.values) {
           final localPath = f['originalRelPath'] as String;
           if (localPath.contains(cloudTitleId)) {
               final localParts = localPath.split('/');
               final idx = localParts.indexOf(cloudTitleId);
               final base = localParts.sublist(0, idx).join('/');
               return base.isEmpty ? cloudRelPath : '$base/$cloudRelPath';
           }
       }
       
       // 2. Fallback: Find the FIRST valid 32-char Profile ID on the device (from directory scanner)
       String profileId = '00000000000000000000000000000000';
       final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
       
       // We'll search both files AND directories in the raw scan list
       for (final f in lastScanList) {
           final path = f['relPath'] as String;
           for (final segment in path.split('/')) {
               if (profileRegex.hasMatch(segment) && segment != '00000000000000000000000000000000') {
                   profileId = segment;
                   break;
               }
           }
           if (profileId != '00000000000000000000000000000000') break;
       }
       
       final prefix = hasFilesDir ? 'files/' : '';
       return '${prefix}nand/user/save/0000000000000000/$profileId/$cloudRelPath';
    }
    return cloudRelPath;
  }
}
