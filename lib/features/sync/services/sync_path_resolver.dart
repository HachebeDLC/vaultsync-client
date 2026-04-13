import 'dart:developer' as developer;

class SyncPathResolver {
  String getCloudRelPath(String systemId, String localRelPath, {Map<String, dynamic>? probedMetadata}) {
    final sid = systemId.toLowerCase();
    final parts = localRelPath.split('/');

    // 1. Switch / Eden Logic (Flattened)
    if (sid == 'switch' || sid == 'eden') {
      // Prioritize probed Title ID if available
      final probedTitleId = probedMetadata?['titleId'] as String?;
      if (probedTitleId != null) {
        // Find the Title ID in the path and replace that segment and everything before it
        final titleIdx = parts.indexWhere((p) => RegExp(r'^0100[0-9A-Fa-f]{12}$').hasMatch(p));
        if (titleIdx != -1) {
           return [probedTitleId, ...parts.sublist(titleIdx + 1)].join('/');
        }
        // If not found in path (e.g. folder was renamed), just use TitleID/filename
        final fileName = parts.last;
        return '$probedTitleId/$fileName';
      }

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
         developer.log('RESOLVER: Ignoring non-nested Switch path: $localRelPath', name: 'VaultSync', level: 800);
         return '';
      }

      return parts.sublist(titleIdx).join('/');
    }

    // 2. PS2 / DuckStation Logic (Anchor on memcards)
    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
      final anchors = ['memcards', 'memcard', 'sstates', 'gamesettings'];
      final anchorIdx = parts.lastIndexWhere((p) => anchors.contains(p.toLowerCase()));
      if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
      // No anchor — root-level save file (e.g. EmuDeck pcsx2/saves/Mcd001.ps2).
      // Sync as-is so the file is preserved without forcing a memcards/ subfolder.
      return localRelPath;
    }

    // 4. Dolphin / GameCube / Wii (canonical cloud path)
    if (sid == 'gc' || sid == 'dolphin' || sid == 'wii') {
      // 4a. Specific Wii detection inside generic 'dolphin' system
      if (sid == 'dolphin' && localRelPath.toLowerCase().contains('/wii/title/')) {
         final idx = parts.indexWhere((p) => p.toLowerCase() == 'title');
         if (idx != -1 && idx < parts.length - 1) {
           return parts.sublist(idx + 1).join('/');
         }
      }

      // 4b. Probed GameID (from GCI header)
      final probedGameId = probedMetadata?['gameId'] as String?;
      if (probedGameId != null) {
         final fileName = parts.last;
         final ext = fileName.contains('.') ? fileName.substring(fileName.lastIndexOf('.')) : '.gci';
         return '$probedGameId$ext';
      }

      // 4c. Standard GC anchor
      final gcIdx = parts.indexWhere((p) => p.toLowerCase() == 'gc');
      if (gcIdx != -1) return parts.sublist(gcIdx + 1).join('/');
      
      // 4d. Fallback for Wii if sid was explicitly 'wii'
      if (sid == 'wii') {
        final titleIdx = parts.lastIndexWhere((p) => p.toLowerCase() == 'title');
        if (titleIdx != -1 && titleIdx < parts.length - 1) {
          return parts.sublist(titleIdx + 1).join('/');
        }
      }

      // Prepend GC/ for Dolphin/GC roots
      if (sid != 'wii') return localRelPath;
    }

    // 6. 3DS / Citra / Azahar
    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       final titleIdx = parts.indexOf('00040000');
       if (titleIdx != -1 && titleIdx < parts.length - 1) {
           return 'saves/${parts.sublist(titleIdx + 1).join('/')}';
       }
       // EmuDeck / desktop flat structure: scan root is azahar/saves/ or citra/saves/.
       // Prefix with saves/ to keep the cloud namespace consistent.
       return 'saves/$localRelPath';
    }

    if (sid == 'psp' || sid == 'ppsspp') {
       final probedGameId = probedMetadata?['gameId'] as String?;
       if (probedGameId != null) {
          return 'SAVEDATA/$probedGameId';
       }
       final anchorIdx = parts.indexWhere((p) => ['savedata', 'ppsspp_state'].contains(p.toLowerCase()));
       if (anchorIdx != -1) return parts.sublist(anchorIdx).join('/');
    }

    // 8. RetroArch (Universal Core Logic)
    if (sid.contains('retroarch') || localRelPath.toLowerCase().contains('retroarch')) {
      final anchorIdx = parts.indexWhere((p) => ['saves', 'states'].contains(p.toLowerCase()));
      if (anchorIdx != -1) {
        return parts.sublist(anchorIdx + 1).join('/');
      }
      
      // If we are in a package root (no folders yet) and it's not a known save folder, 
      // ignore it to prevent syncing internal app files.
      return '';
    }

    return localRelPath;
  }

  String getLocalRelPath(String systemId, String cloudRelPath, Map<String, dynamic> localFiles, List<dynamic> lastScanList, {String? probedProfileId}) {
    final sid = systemId.toLowerCase();
    final isSwitch = sid == 'switch' || sid == 'eden';
    
    final cloudPrefix = isSwitch 
      ? 'switch' 
      : (sid.contains('retroarch') || cloudRelPath.toLowerCase().startsWith('retroarch/') ? 'RetroArch' : (sid == 'gc' || sid == 'dolphin' ? 'GC' : systemId));
    
    // Normalize: strip the cloud prefix if it exists to get the true relative path.
    String relPath = cloudRelPath;
    if (relPath.toLowerCase().startsWith('${cloudPrefix.toLowerCase()}/')) {
      relPath = relPath.substring(cloudPrefix.length + 1);
    }

    // 0. Direct lookup (normalized cloud keys)
    if (!isSwitch && localFiles.containsKey(relPath)) {
      return localFiles[relPath]['originalRelPath'] ?? relPath;
    }

    // 1. RetroArch (Core-aware mapping)
    if (sid.contains('retroarch') || cloudRelPath.toLowerCase().startsWith('retroarch/')) {
       final suffix = relPath;
       
       final isState = suffix.toLowerCase().contains('.state') || suffix.toLowerCase().endsWith('.png');
       final folder = isState ? 'states' : 'saves';

       final hasExplicitAnchor = lastScanList.any((f) {
          final p = (f['relPath'] as String).toLowerCase();
          return p.startsWith('saves/') || p.startsWith('states/');
       });

       final hasFilesDir = lastScanList.any((f) => (f['relPath'] as String).startsWith('files/'));

       if (hasExplicitAnchor) {
           return hasFilesDir ? 'files/$folder/$suffix' : '$folder/$suffix';
       }

       return hasFilesDir ? 'files/$folder/$suffix' : '$folder/$suffix';
    }

    if (isSwitch) {
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

       final profileId = foundProfileId ?? '00000000000000000000000000000000';
       final result = 'nand/user/save/0000000000000000/$profileId/$relPath';
       developer.log('RESOLVER: Switch Target -> $result (Detected: ${foundProfileId ?? "NONE"})', name: 'VaultSync', level: 800);
       return result;
    }

    final hasFilesDir = lastScanList.any((f) => (f['relPath'] as String).startsWith('files/'));
    final prefix = hasFilesDir ? 'files/' : '';

    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
       return '$prefix$relPath';
    }

    if (sid == 'wii') {
       final isWiiRooted = !hasFilesDir && lastScanList.isNotEmpty && lastScanList.any((f) => (f['relPath'] as String).startsWith('title/'));
       if (isWiiRooted) return 'title/$relPath';
       const knownTitleTypes = ['00010000', '00010001', '00010002', '00010004', '00010005'];
       if (knownTitleTypes.contains(relPath.split('/').first)) return '${prefix}Wii/title/$relPath';
       return '${prefix}Wii/title/00010000/$relPath';
    }

    if (sid == 'gc' || sid == 'dolphin') {
       final hasGcPrefixPaths = lastScanList.any((f) => (f['relPath'] as String).startsWith('GC/'));
       final isGcRooted = !hasFilesDir && lastScanList.isNotEmpty && !hasGcPrefixPaths;
       if (isGcRooted && relPath.startsWith('GC/')) {
         return relPath.substring(3);
       }
       return '$prefix$relPath';
    }

    if (sid == '3ds' || sid == 'citra' || sid == 'azahar') {
       final isRooted = lastScanList.any((f) => (f['relPath'] as String).startsWith('title/'));
       if (!isRooted) return '${prefix}saves/$relPath';
       if (relPath.startsWith('saves/')) return relPath.substring(6);
       return relPath;
    }

    if (sid == 'psp' || sid == 'ppsspp') {
       if (!relPath.startsWith('SAVEDATA') && !relPath.startsWith('PPSSPP_STATE')) {
          return 'SAVEDATA/$relPath';
       }
       return relPath;
    }

    return relPath;
  }
}
