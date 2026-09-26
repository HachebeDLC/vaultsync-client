import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Utility for recursively scanning the local filesystem for emulator-specific save files.
class DartFileScanner {
  static const _syncEverythingSids = {'switch', 'eden'};

  // Global save-extension fallback. Used only when the per-system list is
  // empty. Curated to exclude generic / dangerous extensions: ".save", ".bin"
  // (too generic), ".dat" (covers/config on multiple emulators), ".bak"
  // (RetroArch's local save-rotation backups).
  @visibleForTesting
  static const globalSaveExtensions = {
    "srm", "state", "auto", "mcd", "mcr", "ps2", "gci", "raw",
    "dsv", "dss", "vms", "vmu", "eep", "sra", "fla", "mpk",
    "bcr", "ngf", "ngs", "sav", "png", "vfs",
    "nv", "rtc", "mcx", "mc", "dsx"
  };

  /// Directory (or file) names that never hold saves, matched at any depth.
  ///
  /// The RetroArch entries matter for cost, not correctness: its root holds
  /// `cheats/` — 28k files on a stock install — against 27 real saves. A system
  /// rooted at the RetroArch folder so that `saves/` and `states/` both resolve
  /// would otherwise walk all of it on every scan.
  static const _hardcodedIgnores = {
    "cache", "shaders", "resourcepack", "load",
    "log", "logs", "temp", "tmp", "bios", "covers",
    "textures", "custom_textures", "game",
    // RetroArch bulk directories.
    "cheats", "thumbnails", "downloads", "assets", "cores",
    "database", "info", "overlays", "filters", "records", "screenshots",
  };

  /// Collapses RetroArch's numbered savestate slots onto the `state` extension.
  ///
  /// A manual savestate is written as `<rom>.state1`, `.state2`, … while slot 0
  /// is plain `.state` and the automatic one ends in `.state.auto`. Only the
  /// last two are listed in the per-system `save_extensions`, so every manual
  /// slot was silently skipped: an Emerald `.state1` sat on a device for a day
  /// without ever being backed up. Normalising here beats adding state1..state9
  /// to all 133 system files.
  @visibleForTesting
  static String normaliseSaveExtension(String ext) =>
      RegExp(r'^state\d+$').hasMatch(ext) ? 'state' : ext;

  /// Whether any directory component of [relPath] is hidden (starts with `.`).
  /// The trailing component is the file itself and is checked separately.
  static bool _hasHiddenSegment(String relPath) {
    final parts = relPath.replaceAll('\\', '/').split('/');
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i].startsWith('.')) return true;
    }
    return false;
  }

  /// Also applied to remote RetroArch keys in SyncRepository.syncSystem, so a
  /// system never compares files its own local scan would not have listed.
  static bool shouldSyncFile(
    String sid,
    String relPath,
    String fileName, {
    Set<String>? saveExtensions,
  }) {
    if (fileName.startsWith(".")) return false;
    // RetroArch rotates the previous save/state to .bak on every write.
    // Reject before the per-system extension check so it can never be
    // re-allowed by a system whose JSON happens to list "bak".
    if (fileName.toLowerCase().endsWith(".bak")) return false;
    // VaultSync's own partial-transfer files (see dart_native_crypto.dart).
    // Without this they were scanned as saves and uploaded — one abandoned
    // .vstmp reached the server at 79 MB.
    if (fileName.toLowerCase().endsWith(".vstmp")) return false;
    // Hidden *directories* anywhere in the path. The fileName check above only
    // catches hidden files, so everything inside Syncthing's `.stversions/`
    // trash passed with an ordinary name and got synced as real saves.
    if (_hasHiddenSegment(relPath)) return false;

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

    final ext = normaliseSaveExtension(
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : "");
    if (ext.isEmpty) return false;
    final allowed = (saveExtensions != null && saveExtensions.isNotEmpty)
        ? saveExtensions
        : globalSaveExtensions;
    return allowed.contains(ext);
  }

  /// Recursively walks the directory at `rootPath` and returns a metadata list of
  /// files that match the synchronization rules for `systemId`.
  ///
  /// When `saveExtensions` is non-empty the scanner uses it instead of
  /// [globalSaveExtensions] for the final extension check. Prefix-based
  /// filters (PSP `savedata/`, Wii `title/0001000`, etc.) still apply.
  static Future<List<Map<String, dynamic>>> scanRecursive(
    String rootPath,
    String systemId,
    List<String> ignoredFolders, {
    List<String> saveExtensions = const [],
  }) async {
    final sid = systemId.toLowerCase();
    final results = <Map<String, dynamic>>[];
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) return results;

    final ignoreSet = ignoredFolders.map((e) => e.toLowerCase()).toSet();
    final saveExtSet = saveExtensions.map((e) => e.toLowerCase()).toSet();
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
            if (shouldSyncFile(sid, relPath, fileName, saveExtensions: saveExtSet)) {
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
