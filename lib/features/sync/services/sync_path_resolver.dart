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

  /// Normalizes the `files/` alias in a remote file-listing map for a system
  /// whose local scan root is itself an Android/data package's `files/`
  /// directory (see `SystemPathService.isPackageFilesDir`,
  /// `packageRootFilesTreeUri` and `packageRootFilesPosixPath`).
  ///
  /// Evidence (real device): melonDS's local root is
  /// `.../Android/data/me.magnum.melonds/files`, and its saves scan as
  /// `saves/<name>.sav` relative to that root. Another device on the same
  /// account had melonDS configured at the *package* root instead
  /// (`.../me.magnum.melonds`, one level up) and so uploaded the same files
  /// as `files/saves/<name>.sav` — the `files/` segment baked into the cloud
  /// path because, from that root, it really was part of the relative path.
  /// Once the local root is `.../files`, `files/saves/<name>.sav` and
  /// `saves/<name>.sav` are the exact same on-disk file, but as plain map
  /// keys they never match: `files/saves/X` always looks remote-only against
  /// a local scan keyed by `saves/X`, so it is downloaded to
  /// `<root>/files/saves/X` (a nested duplicate) on every single sync,
  /// forever, regardless of content.
  ///
  /// [rootIsPackageFilesDir] gates the whole rewrite: pass
  /// `SystemPathService.isPackageFilesDir(effectiveRoot)`. When false, this
  /// returns [remoteFiles] unchanged — a top-level `files/` segment is only
  /// ever this alias when the scan root truly is a package's `files/` dir;
  /// for any other root it might be a real, meaningfully-named subfolder.
  ///
  /// When both the aliased (`files/x`) and canonical (`x`) keys are present
  /// in [remoteFiles] at once (e.g. one device uploaded both ways over time),
  /// the canonical key wins — it is what every scan of this root actually
  /// produces — and the alias is dropped rather than merged, reported via
  /// [onDuplicate] so the caller can log it. This never renames or deletes
  /// anything server-side; it only changes which cloud entry this device's
  /// diff compares its local file against.
  static Map<String, dynamic> dealiasFilesRootRemoteKeys(
    Map<String, dynamic> remoteFiles, {
    required bool rootIsPackageFilesDir,
    void Function(String canonicalKey, String aliasedKey)? onDuplicate,
  }) {
    if (!rootIsPackageFilesDir) return remoteFiles;
    const prefix = 'files/';

    final result = <String, dynamic>{};
    for (final entry in remoteFiles.entries) {
      final key = entry.key;
      if (!key.startsWith(prefix) || key.length <= prefix.length) {
        result[key] = entry.value;
      }
    }
    for (final entry in remoteFiles.entries) {
      final key = entry.key;
      if (key.startsWith(prefix) && key.length > prefix.length) {
        final canonicalKey = key.substring(prefix.length);
        if (remoteFiles.containsKey(canonicalKey)) {
          onDuplicate?.call(canonicalKey, key);
          continue;
        }
        result[canonicalKey] = entry.value;
      }
    }
    return result;
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
       // A SAF root at the package/`files` level (see
       // SystemPathService.isPackageFilesDir) already scans with a leading
       // `saves/` segment baked into the relative path — e.g.
       // `saves/<titleid>/...`. Without this check the fallback below always
       // prepended another `saves/`, producing a doubled
       // `.../saves/saves/<titleid>/...` cloud path that never matched this
       // device's own local scan (which recomputes the same doubled key
       // deterministically, so it "worked" locally) but did not match a
       // canonical `saves/<titleid>/...` row from any other device, and
       // downloaded into `Azahar/saves/saves/…` on a fresh install. Only
       // prepend when the segment isn't already there.
       if (localRelPath.toLowerCase().startsWith('saves/')) return localRelPath;
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

       final hasExplicitAnchor = retroArchScanHasAnchor(lastScanList);

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
           final rootAnchor = retroArchRootAnchor(localRoot);
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
       // Evidence (real device, POCO F8 Pro): Azahar/Citra really stores saves
       // at `<sdmc-prefix>/title/00040000/<titleid>/data/00000001/<file>`
       // (e.g. `sdmc/Nintendo 3DS/<id0>/<id1>/title/00040000/<titleid>/...`),
       // never at the SAF root's `saves/<titleid>/...`. The scanner
       // (DartFileScanner/FileScanner.shouldSyncFile) only ever syncs local
       // paths that contain a `title/00040000` component, so downloading a
       // remote-only `saves/<titleid>/...` cloud key to `saves/<titleid>/...`
       // (the old fallback below) puts the file somewhere the scanner never
       // looks: it is never recognized as already-local, and the same remote
       // key is re-downloaded on every subsequent sync forever, without the
       // game (which reads only the real sdmc path) ever seeing it. When the
       // local scan already contains at least one real
       // `.../title/00040000/<titleid>/...` save, mirror that same prefix for
       // this file so it lands where both the scanner and the emulator expect
       // it. Guarded to leave a cloud path that already carries a
       // `title/00040000` component (i.e. is already in local-path shape)
       // untouched. With no local title/00040000 folder to copy the prefix
       // from, Azahar's default layout under the root is used instead.
       if (!relPath.toLowerCase().contains('title/00040000')) {
         final titleSavesMatch =
             RegExp(r'^saves/([0-9A-Fa-f]{8})(?:/(.*))?$').firstMatch(relPath);
         if (titleSavesMatch != null) {
           final titleId = titleSavesMatch.group(1)!;
           final rest = titleSavesMatch.group(2);
           // No local save to copy the layout from (Retroid Pocket Nova: the
           // Azahar folder holds only config/gpu_drivers/log, so 12 files
           // were re-downloaded to Azahar/saves/ on every sync). Fall back
           // to Azahar's own default layout, the one the POCO F8 Pro has.
           final sdmcPrefix = _find3dsSdmcPrefix(lastScanList) ??
               default3dsSdmcPrefix(localRoot);
           if (sdmcPrefix != null) {
             final destTail = (rest == null || rest.isEmpty)
                 ? 'title/00040000/$titleId'
                 : 'title/00040000/$titleId/$rest';
             final dest = sdmcPrefix.isEmpty ? destTail : '$sdmcPrefix/$destTail';
             developer.log(
                 'RESOLVER: 3DS remote-only "$cloudRelPath" -> "$dest" '
                 '(mirrored sdmc title/00040000 prefix)',
                 name: 'VaultSync',
                 level: 800);
             return dest;
           }
         }
       }

       final isRooted = lastScanList.any((f) => (f['relPath'] as String).startsWith('title/'));
       if (!isRooted) {
         // Mirror image of the getCloudRelPath fix above: a SAF root at the
         // package/`files` level scans with `relPath` already carrying the
         // `saves/` segment (e.g. `saves/<titleid>/...`), so prepending
         // another one here produced the same `saves/saves/…` doubling on
         // download that the upload side used to produce.
         if (relPath.toLowerCase().startsWith('saves/')) return '$prefix$relPath';
         return '${prefix}saves/$relPath';
       }
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

  /// Whether [root] (a system's configured local scan root) points *at* one
  /// of RetroArch's two save folders — i.e. its last path segment is `saves`
  /// or `states`. Returns that leaf, lowercased, or null otherwise (including
  /// a root above both folders, at the RetroArch folder itself, or no root at
  /// all).
  ///
  /// Factored out of [getLocalRelPath]'s RetroArch anchor logic so
  /// [SyncRepository.syncSystem] can apply the exact same "is this root
  /// anchored at saves/states?" test when normalizing the *remote* file
  /// listing's keys — see [normalizeRetroArchRemoteKey].
  static String? retroArchRootAnchor(String? root) {
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

  /// Whether a raw file-scan listing (each entry a map with a `relPath` key,
  /// as produced by the file scanner and threaded through as `lastScanList`)
  /// already contains files anchored under RetroArch's `saves/` or `states/`
  /// folders.
  ///
  /// When this is false for a RetroArch-namespaced system, the configured
  /// root sits *inside* one of those two folders rather than at or above
  /// RetroArch itself, so local scan keys never carry the anchor — see
  /// [getLocalRelPath]'s RetroArch branch (which strips the anchor off a
  /// *cloud* path before joining it under such a root) and
  /// [normalizeRetroArchRemoteKey] (which strips the same anchor off a
  /// *remote listing* key for the same reason, so uploads and the existing
  /// remote copy are recognized as the same file instead of endlessly
  /// re-downloading a remote-looking duplicate).
  static bool retroArchScanHasAnchor(List<dynamic> scanList) {
    return scanList.any((f) {
      final p = (f['relPath'] as String).toLowerCase();
      return p.startsWith('saves/') || p.startsWith('states/');
    });
  }

  /// Rewrites a single RetroArch remote-listing key (already stripped of the
  /// `RetroArch/` cloud prefix, e.g. `saves/Metroid Fusion (USA).srm`) to the
  /// un-anchored key a local scan rooted directly at `saves/` or `states/`
  /// would produce for the same file (e.g. `Metroid Fusion (USA).srm`).
  ///
  /// This is the upload-side counterpart of what [getLocalRelPath] already
  /// does for downloads: when the configured root for a RetroArch-namespaced
  /// system (e.g. `nds`, `gba`) is itself `.../RetroArch/saves` rather than
  /// `.../RetroArch`, [getCloudRelPath] never recognizes the file as
  /// RetroArch's at all (neither `systemId` nor the bare local filename
  /// contains "retroarch"), so it falls through to an un-anchored local key.
  /// Every sync then compared that un-anchored local key against the
  /// server's anchored `saves/x` / `states/x` listing, found no match, and
  /// re-queued the remote copy as a same-content "download" forever. Calling
  /// this on every entry of the remote listing before the local/remote diff
  /// makes both sides agree on the same un-anchored key so identical files
  /// compare equal — see [SyncRepository.syncSystem].
  ///
  /// Leaves [remoteKey] unchanged unless all of:
  /// - [localScanHasAnchor] is false (the local scan itself has no anchor,
  ///   i.e. the root really is inside `saves/` or `states/` — see
  ///   [retroArchScanHasAnchor]; when the local scan already carries the
  ///   anchor, both sides are already directly comparable and rewriting
  ///   would instead cause a collision), and
  /// - [rootAnchor] (from [retroArchRootAnchor]) is non-null, and
  /// - [remoteKey] starts with that *same* anchor (`saves/` or `states/`). A
  ///   remote key under the sibling anchor — e.g. a `states/x` row when the
  ///   root is rooted at `saves/` — is left alone: it does not belong under
  ///   this root at all (mirroring [getLocalRelPath]'s sibling-anchor skip),
  ///   and leaving its key anchored means it can never collide with an
  ///   unrelated local file of the same bare name.
  static String normalizeRetroArchRemoteKey(
    String remoteKey, {
    required String? rootAnchor,
    required bool localScanHasAnchor,
  }) {
    if (localScanHasAnchor || rootAnchor == null) return remoteKey;
    final lower = remoteKey.toLowerCase();
    final remoteAnchor = lower.startsWith('saves/')
        ? 'saves'
        : (lower.startsWith('states/') ? 'states' : null);
    if (remoteAnchor == null || remoteAnchor != rootAnchor) return remoteKey;
    return remoteKey.substring(remoteAnchor.length + 1);
  }

  /// Normalizes a remote-file listing for a 3DS/Citra/Azahar system by
  /// collapsing a leading doubled `saves/saves/` segment back to the
  /// canonical single `saves/`.
  ///
  /// [getCloudRelPath]'s 3DS branch used to unconditionally prepend `saves/`
  /// even when the scanned relative path already started with `saves/` (true
  /// for a SAF root at the package/`files` level — see
  /// [SystemPathService.isPackageFilesDir]), producing and uploading a
  /// doubled `3ds/saves/saves/<titleid>/...` cloud path. That fallback is now
  /// fixed to leave an already-anchored path alone, but a row the server
  /// already holds under the old doubled key would otherwise still look
  /// remote-only forever against this device's (now-canonical) local scan
  /// key and get re-downloaded as a duplicate. Rewriting the doubled key back
  /// to canonical here makes the diff compare it against the real local file
  /// instead.
  ///
  /// When both a doubled key and its canonical counterpart are present at
  /// once, the canonical one wins and the doubled one is dropped, reported
  /// via [onDuplicate] — mirroring [dealiasFilesRootRemoteKeys]. This never
  /// renames or deletes anything server-side.
  static Map<String, dynamic> dealias3dsDoubledSavesRemoteKeys(
    Map<String, dynamic> remoteFiles, {
    void Function(String canonicalKey, String aliasedKey)? onDuplicate,
  }) {
    const doubledPrefix = 'saves/saves/';
    final hasDoubled =
        remoteFiles.keys.any((k) => k.toLowerCase().startsWith(doubledPrefix));
    if (!hasDoubled) return remoteFiles;

    final result = <String, dynamic>{};
    for (final entry in remoteFiles.entries) {
      if (!entry.key.toLowerCase().startsWith(doubledPrefix)) {
        result[entry.key] = entry.value;
      }
    }
    for (final entry in remoteFiles.entries) {
      final key = entry.key;
      if (key.toLowerCase().startsWith(doubledPrefix)) {
        final canonicalKey = key.substring('saves/'.length);
        if (remoteFiles.containsKey(canonicalKey)) {
          onDuplicate?.call(canonicalKey, key);
          continue;
        }
        result[canonicalKey] = entry.value;
      }
    }
    return result;
  }

  /// Scans [lastScanList] for real 3DS/Citra/Azahar saves living at
  /// `<prefix>/title/00040000/<8-hex-titleid>/...` and returns the `<prefix>`
  /// segment(s) that precede `title/00040000` (e.g.
  /// `sdmc/Nintendo 3DS/0000000000000000/0000000000000000`, or `''` when
  /// `title/00040000` is itself the first component). Used by
  /// [getLocalRelPath] to place a remote-only `saves/<titleid>/...` cloud
  /// file next to the device's real saves instead of at the SAF root, where
  /// the scanner never looks (see the 3DS branch above for the full story).
  ///
  /// The matched title id in the scanned path need not be the same title id
  /// being resolved — it only tells us which sdmc layout this device uses.
  /// When scan entries disagree (multiple distinct prefixes present), the
  /// most common one is returned and the disagreement is logged; when only
  /// one prefix is present it is returned without logging. Returns null when
  /// no local scan entry has a `title/00040000/<8-hex>` component at all.
  /// Where Azahar/Citra keep saves under [localRoot] when the device has
  /// none yet: `sdmc/Nintendo 3DS/<id0>/<id1>`, with the all-zero ids these
  /// emulators use. The part already covered by the root is dropped, so a
  /// root at `sdmc` or `Nintendo 3DS` still lands in the right folder.
  /// Returns null without a root, or when the root is already inside the
  /// id folders (its depth can't be known from the name).
  static String? default3dsSdmcPrefix(String? localRoot) {
    if (localRoot == null || localRoot.isEmpty) return null;
    const ids = '0000000000000000/0000000000000000';
    final segments = Uri.decodeComponent(localRoot)
        .split(RegExp(r'[/\\:]'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return null;
    final leaf = segments.last.toLowerCase();
    if (leaf == 'sdmc') return 'Nintendo 3DS/$ids';
    if (leaf == 'nintendo 3ds') return ids;
    if (RegExp(r'^[0-9a-f]{16}$').hasMatch(leaf) || leaf == 'title' || leaf == '00040000') {
      return null;
    }
    return 'sdmc/Nintendo 3DS/$ids';
  }

  static String? _find3dsSdmcPrefix(List<dynamic> lastScanList) {
    final titleIdSegment = RegExp(r'^[0-9A-Fa-f]{8}$');
    final counts = <String, int>{};
    final order = <String>[];

    for (final f in lastScanList) {
      final raw = f is Map ? f['relPath'] as String? : null;
      if (raw == null) continue;
      final segments = raw.replaceAll('\\', '/').split('/');
      for (var i = 0; i + 2 < segments.length; i++) {
        if (segments[i].toLowerCase() == 'title' &&
            segments[i + 1] == '00040000' &&
            titleIdSegment.hasMatch(segments[i + 2])) {
          final prefix = segments.sublist(0, i).join('/');
          if (!counts.containsKey(prefix)) order.add(prefix);
          counts[prefix] = (counts[prefix] ?? 0) + 1;
          break;
        }
      }
    }

    if (counts.isEmpty) return null;
    if (counts.length == 1) return order.first;

    var best = order.first;
    var bestCount = counts[best]!;
    for (final p in order) {
      final c = counts[p]!;
      if (c > bestCount) {
        best = p;
        bestCount = c;
      }
    }
    developer.log(
        'RESOLVER: 3DS local scan has multiple sdmc title/00040000 prefixes '
        '$counts — using the most common: "$best"',
        name: 'VaultSync',
        level: 900);
    return best;
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
