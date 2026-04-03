class SyncPathResolver {
  String getCloudRelPath(String systemId, String localRelPath) {
    final sid = systemId.toLowerCase();
    final parts = localRelPath.split('/');
    
    // 1. Switch / Eden Logic (Flattened)
    if (sid == 'switch' || sid == 'eden') {
      // We look for a Title ID (16 hex chars starting with 0100)
      final titleIdx = parts.indexWhere((p) => RegExp(r'^0100[0-9A-Fa-f]{12}$').hasMatch(p));
      if (titleIdx == -1) return '';
      
      // Strict Enforcement: To be valid for cloud mapping, it MUST be nested
      // under a 32-character Profile ID folder.
      final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
      bool isNested = false;
      for (int i = 0; i < titleIdx; i++) {
         if (profileRegex.hasMatch(parts[i])) {
            isNested = true;
            break;
         }
      }
      
      if (!isNested) {
         print('📂 RESOLVER: Ignoring non-nested Switch path: $localRelPath');
         return ''; 
      }
      
      return parts.sublist(titleIdx).join('/');
    } 
    
    // 2. PS2 / DuckStation Logic (Anchor on memcards)
    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
      final anchors = ['memcards', 'memcard', 'sstates', 'gamesettings'];
      final anchorIdx = parts.lastIndexWhere((p) => anchors.contains(p.toLowerCase()));
      if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
      return '';
    }

    // 3. Wii Logic (Surgical Flattening)
    if (sid == 'wii') {
      // Anchor on the 'title' directory to capture all title types
      // (00010000 = retail, 00010001 = VC/DLC, 00010002 = system, 00010004 = WiiWare, etc.)
      final titleIdx = parts.lastIndexWhere((p) => p.toLowerCase() == 'title');
      if (titleIdx != -1 && titleIdx < parts.length - 1) {
        return parts.sublist(titleIdx + 1).join('/');
      }
      return '';
    }

    // 4. GameCube Logic (Preserve GC/ prefix)
    if (sid == 'gc') {
      final gcIdx = parts.indexWhere((p) => p.toLowerCase() == 'gc');
      if (gcIdx != -1) return parts.sublist(gcIdx).join('/');
      return '';
    }

    // 5. Dolphin (Generic)
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

    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       final titleIdx = parts.indexOf('00040000');
       if (titleIdx != -1 && titleIdx < parts.length - 1) {
           return 'saves/${parts.sublist(titleIdx + 1).join('/')}';
       }
       return '';
    }

    if (sid == 'psp' || sid == 'ppsspp') {
       final anchorIdx = parts.indexWhere((p) => ['savedata', 'ppsspp_state'].contains(p.toLowerCase()));
       if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
    }

    return localRelPath;
  }

  String getLocalRelPath(String systemId, String cloudRelPath, Map<String, dynamic> localFiles, List<dynamic> lastScanList, {String? probedProfileId}) {
    final sid = systemId.toLowerCase();
    final isSwitch = sid == 'switch' || sid == 'eden';
    
    // For Switch, NEVER anchor on root-level files
    if (!isSwitch && localFiles.containsKey(cloudRelPath)) {
      return localFiles[cloudRelPath]['originalRelPath'] ?? cloudRelPath;
    }
    
    if (isSwitch) {
       // Probing: Use the explicitly provided profile ID or find the FIRST valid 32-char Profile ID on the device
       String? foundProfileId = probedProfileId;
       final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');

       if (foundProfileId == null) {
         for (final f in lastScanList) {
             final path = f['relPath'] as String;
             final segments = path.split('/');
             for (final segment in segments) {
                 if (profileRegex.hasMatch(segment) && segment != '00000000000000000000000000000000') {
                     foundProfileId = segment;
                     break;
                 }
             }
             if (foundProfileId != null) break;
         }
       }

       // Final fallback if no profile discovered yet
       final profileId = foundProfileId ?? '00000000000000000000000000000000';

       // We assume the root is the emulator root ('files/').
       // We ALWAYS anchor on 'nand/user/save' for consistency.
       final result = 'nand/user/save/0000000000000000/$profileId/$cloudRelPath';
       print('📂 RESOLVER: Switch Target -> $result (Detected: ${foundProfileId ?? "NONE"})');
       return result;
    }

    final hasFilesDir = lastScanList.any((f) => (f['relPath'] as String).startsWith('files/'));

    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
       final prefix = hasFilesDir ? 'files/' : '';
       if (cloudRelPath.startsWith('memcards/') || cloudRelPath.startsWith('memcard/') || cloudRelPath.startsWith('sstates/') || cloudRelPath.startsWith('gamesettings/')) {
          return '$prefix$cloudRelPath';
       }
       return '${prefix}memcards/$cloudRelPath';
    }

    if (sid == 'wii') {
       final prefix = hasFilesDir ? 'files/' : '';
       // cloudRelPath now includes the title type, e.g. '00010000/GAMEID/data.bin'.
       // For backward compat with old saves that lack the title type prefix, fall back to 00010000.
       const knownTitleTypes = ['00010000', '00010001', '00010002', '00010004', '00010005'];
       if (knownTitleTypes.contains(cloudRelPath.split('/').first)) {
         return '${prefix}Wii/title/$cloudRelPath';
       }
       return '${prefix}Wii/title/00010000/$cloudRelPath';
    }

    if (sid == 'gc' || sid == 'dolphin') {
       final prefix = hasFilesDir ? 'files/' : '';
       return '$prefix$cloudRelPath';
    }

    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       if (cloudRelPath.startsWith('saves/')) {
          final suffix = cloudRelPath.substring(6);
          final prefix = hasFilesDir ? 'files/' : '';
          return '${prefix}sdmc/Nintendo 3DS/0000000000000000/0000000000000000/title/00040000/$suffix';
       }
       return cloudRelPath;
    }

    if (sid == 'psp' || sid == 'ppsspp') {
       if (!cloudRelPath.startsWith('SAVEDATA') && !cloudRelPath.startsWith('PPSSPP_STATE')) {
          return 'SAVEDATA/$cloudRelPath';
       }
       return cloudRelPath;
    }

    return cloudRelPath;
  }
}
