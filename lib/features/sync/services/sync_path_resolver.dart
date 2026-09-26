import 'dart:developer' as developer;

class SyncPathResolver {
  /// Mirrors the server's Wii/GC/Dolphin NAND-blob quarantine rule exactly —
  /// see `vaultsync_server/app/cleanup_garbage.py`'s `_is_wii_nand_blob`:
  ///
  ///   top = path.split('/')[0].lower()
  ///   if top not in ('wii', 'dolphin', 'gc'): return False
  ///   return path.lower().endswith(('.app', '.tmd', '.wad'))
  ///
  /// [cloudPath] must be the FULL cloud-relative path, including the
  /// top-level system segment (e.g. `wii/00010008/.../content/0000001c.app`),
  /// not a path already stripped of it. The server quarantines these NAND
  /// install/title-metadata blobs as garbage — a download of one 404s, and an
  /// upload of one just gets quarantined right back — so the client must
  /// never queue them for either direction in the first place. Case
  /// -insensitive on both the top segment and the suffix, exactly like the
  /// server.
  static bool isWiiNandBlobCloudPath(String cloudPath) {
    final parts = cloudPath.split('/');
    if (parts.isEmpty) return false;
    final top = parts.first.toLowerCase();
    if (top != 'wii' && top != 'dolphin' && top != 'gc') return false;
    final lower = cloudPath.toLowerCase();
    return lower.endsWith('.app') || lower.endsWith('.tmd') || lower.endsWith('.wad');
  }


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
      // 4-pre. Reject Wii NAND content / title metadata. These appear when a
      // user points the local Wii path at a NAND mount — they're install data,
      // not saves, and historically polluted wii/ with thousands of .app blobs.
      final lowerFile = parts.last.toLowerCase();
      if (lowerFile.endsWith('.app') || lowerFile.endsWith('.tmd') || lowerFile.endsWith('.wad')) {
        developer.log('RESOLVER: Skipping Wii NAND content file: $localRelPath', name: 'VaultSync', level: 800);
        return '';
      }

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
       // No SAVEDATA/PPSSPP_STATE anchor and no probed gameId — stray file at
       // scan root. Skip rather than dumping it at psp/ root (historical bug).
       developer.log('RESOLVER: Skipping non-anchored PSP file: $localRelPath', name: 'VaultSync', level: 800);
       return '';
    }

    // 8. RetroArch (Universal Core Logic)
    if (sid.contains('retroarch') || localRelPath.toLowerCase().contains('retroarch')) {
      // 8-pre. RetroArch rotates the previous save to `.bak` every time it
      // writes a new save/state. These are local-only backups and historically
      // polluted the server (RetroArch/{saves,states,files,<core>}/*.bak).
      if (parts.last.toLowerCase().endsWith('.bak')) {
        developer.log('RESOLVER: Skipping RetroArch .bak rotation file: $localRelPath', name: 'VaultSync', level: 800);
        return '';
      }

      final anchorIdx = parts.indexWhere((p) => ['saves', 'states'].contains(p.toLowerCase()));
      if (anchorIdx != -1) {
        return parts.sublist(anchorIdx).join('/');
      }
      
      // Fallback: Route based on extension if we are syncing a subfolder directly (e.g. per-core)
      final fileName = parts.last.toLowerCase();
      if (fileName.endsWith('.state') || fileName.contains('.state') || fileName.endsWith('.s00') || RegExp(r'\.s\d+$').hasMatch(fileName)) {
        return 'states/$localRelPath';
      }
      if (fileName.endsWith('.srm') || fileName.endsWith('.sav') || fileName.endsWith('.save')) {
        return 'saves/$localRelPath';
      }

      // If we can't identify it, return empty to prevent syncing junk from RA root
      return '';
    }

    return localRelPath;
  }

  /// Maps a cloud-relative path to a path relative to the system's configured
  /// root. Returns null when the file cannot be placed under that root without
  /// landing in the wrong folder; the caller must skip it.
  ///
  /// [localRoot] is the system's effective root. It is optional only so that
  /// older callers and tests keep working — without it the RetroArch branch
  /// falls back to the anchor-blind behaviour described below.
  String? getLocalRelPath(String systemId, String cloudRelPath, Map<String, dynamic> localFiles, List<dynamic> lastScanList, {String? probedProfileId, String? localRoot}) {
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
       var suffix = relPath;
       
       final hasExplicitAnchor = lastScanList.any((f) {
          final p = (f['relPath'] as String).toLowerCase();
          return p.startsWith('saves/') || p.startsWith('states/');
       });

       // The local scan has no `saves/` or `states/` anchor, so the configured
       // root is *inside* one of them and the anchor has to come off for the
       // path to resolve. Which anchor may come off depends on which one the
       // root is: stripping both collapses the two folders into one.
       //
       // That is not hypothetical. With gba/snes/n64/ps1 all rooted at
       // `RetroArch/saves`, every `RetroArch/states/x` in the cloud was written
       // to `RetroArch/saves/x`, re-uploaded from there, and re-downloaded on
       // the next sync — the savestate duplication we kept clearing by hand.
       if (!hasExplicitAnchor) {
         final lower = suffix.toLowerCase();
         final cloudAnchor = lower.startsWith('saves/')
             ? 'saves'
             : (lower.startsWith('states/') ? 'states' : null);

         if (cloudAnchor != null) {
           final rootAnchor = _anchorOf(localRoot);
           if (localRoot == null || rootAnchor == cloudAnchor) {
             // Root is that folder (or unknown, keeping the old behaviour).
             suffix = suffix.substring(cloudAnchor.length + 1);
           } else if (rootAnchor != null) {
             // Root is the *sibling* anchor. Writing here would merge the two
             // folders, so leave the file alone and say why.
             developer.log(
                 'RESOLVER: $systemId is rooted at $rootAnchor/ but "$cloudRelPath" '
                 'belongs under $cloudAnchor/ — skipping. Point the system at the '
                 'RetroArch folder itself to sync both.',
                 name: 'VaultSync',
                 level: 1000);
             return null;
           }
           // rootAnchor == null: the root sits above both anchors, so the
           // anchor is part of the destination and must be kept.
         }
       }

       final hasFilesDir = lastScanList.any((f) => (f['relPath'] as String).startsWith('files/'));
       return hasFilesDir ? 'files/$suffix' : suffix;
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

  /// Drops a leading segment of [relPath] that merely repeats the last segment
  /// of [localRoot], so a root configured one level too deep does not produce a
  /// self-nested copy.
  ///
  /// [getLocalRelPath] returns a path relative to the system's configured root
  /// and the caller joins the two. When the root already *is* the folder the
  /// relative path starts with, the join duplicates it. Pointing psp at
  /// `PPSSPP/PSP/SAVEDATA` instead of `PPSSPP/PSP` is what produced
  /// `PSP/SAVEDATA/SAVEDATA/…` and `PSP/SAVEDATA/PPSSPP_STATE/…` — hundreds of
  /// duplicated files, uploaded back and re-downloaded on every later sync.
  ///
  /// Only one segment is dropped, and only on an exact case-insensitive match,
  /// so a root at the right level is never altered.
  /// `saves` or `states` when [root] points *at* one of RetroArch's two save
  /// folders, null otherwise (including a root above them, or no root at all).
  static String? _anchorOf(String? root) {
    if (root == null || root.isEmpty) return null;
    final parts = root
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final leaf = parts.last.toLowerCase();
    return (leaf == 'saves' || leaf == 'states') ? leaf : null;
  }

  static String dedupeRootSegment(String localRoot, String relPath) {
    if (localRoot.isEmpty || relPath.isEmpty) return relPath;

    String lastSegment(String p) {
      final parts = p
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      return parts.isEmpty ? '' : parts.last;
    }

    final root = lastSegment(localRoot);
    if (root.isEmpty) return relPath;

    final slash = relPath.indexOf('/');
    if (slash <= 0) return relPath; // single segment: nothing to de-duplicate
    final head = relPath.substring(0, slash);
    if (head.toLowerCase() != root.toLowerCase()) return relPath;

    return relPath.substring(slash + 1);
  }
}
