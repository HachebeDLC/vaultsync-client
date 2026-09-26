import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import '../../emulation/data/emulator_repository.dart';
import '../../emulation/domain/emulator_config.dart';

final systemPathServiceProvider = Provider<SystemPathService>((ref) {
  final emulatorRepo = ref.watch(emulatorRepositoryProvider);
  return SystemPathService(emulatorRepo);
});

final systemPathsProvider = FutureProvider<Map<String, String>>((ref) async {
  final service = ref.watch(systemPathServiceProvider);
  await service.getStorageVersion();
  await service.purgeOrphanedPaths();
  return service.getAllSystemPaths();
});

/// Outcome of [SystemPathService.decidePackageRootMigration].
enum PackageRootMigrationOutcome {
  /// [rawPath] isn't a bare Switch/Eden package-root SAF tree — nothing to do.
  notApplicable,

  /// A SAF grant for the `/files` subfolder is already held; the caller
  /// should switch to [PackageRootMigrationResult.migratedPath] and persist it.
  migrated,

  /// [rawPath] is a package-root tree, but no grant is held for `/files` —
  /// the caller should leave the path as-is and warn instead of guessing.
  blockedNoGrant,
}

/// Result of [SystemPathService.decidePackageRootMigration].
class PackageRootMigrationResult {
  final PackageRootMigrationOutcome outcome;

  /// Set only when [outcome] is [PackageRootMigrationOutcome.migrated].
  final String? migratedPath;

  const PackageRootMigrationResult(this.outcome, [this.migratedPath]);
}

/// Service responsible for resolving platform-specific emulator paths and
/// identifying game save locations.
class SystemPathService {
  final EmulatorRepository _emulatorRepository;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  Map<String, String>? _cachedPaths;
  Map<String, dynamic>? _config;

  SystemPathService(this._emulatorRepository);
  EmulatorRepository getEmulatorRepository() => _emulatorRepository;

  Future<void> _ensureConfigLoaded() async {
    if (_config != null) return;
    try {
      final jsonStr =
          await rootBundle.loadString('assets/config/path_config.json');
      _config = json.decode(jsonStr);
    } catch (e) {
      developer.log('CONFIG: Failed to load path_config.json',
          name: 'VaultSync', level: 900, error: e);
      _config = {};
    }
  }

  String _getDesktopHome() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
    }
    return Platform.environment['HOME'] ?? '/home';
  }

  Future<String?> _getDesktopDefault(String key, String systemId) async {
    await _ensureConfigLoaded();
    final home = _getDesktopHome();
    final platform = Platform.isWindows ? 'windows' : 'linux';

    final Map? platformPaths = _config?['desktopPaths']?[platform];
    String? path = platformPaths?[key];

    if (path != null) {
      path = path.replaceAll('\$home', home);
      if (key == 'dolphin') {
        if (systemId == 'gc') path = '$path/GC';
        if (systemId == 'wii') path = '$path/Wii';
      }
      // Fix slashes for cross-platform
      if (Platform.isLinux || Platform.isMacOS) {
        path = path.replaceAll('\\', '/');
      }
    }
    return path;
  }

  /// Retrieves all user-configured system paths from local storage.
  /// Filters out orphaned paths that are no longer supported by the current system configs.
  Future<Map<String, String>> getAllSystemPaths() async {
    if (_cachedPaths != null) return _cachedPaths!;

    final prefs = await SharedPreferences.getInstance();
    final validSystems = await _emulatorRepository.loadSystems();
    final validIds = validSystems.map((s) => s.system.id.toLowerCase()).toSet();

    final keys = prefs.getKeys().where((k) => k.startsWith('system_path_'));
    final Map<String, String> paths = {};

    for (final key in keys) {
      final systemId = key.replaceFirst('system_path_', '').toLowerCase();

      // Only include if it's a currently supported system
      if (validIds.contains(systemId)) {
        paths[systemId] = prefs.getString(key)!;
      }
    }

    _cachedPaths = paths;
    return paths;
  }

  /// Automatically removes configurations for systems that are no longer supported
  /// or are duplicates (e.g. legacy psx vs new ps1).
  Future<void> purgeOrphanedPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final validSystems = await _emulatorRepository.loadSystems();
    final validIds = validSystems.map((s) => s.system.id.toLowerCase()).toSet();

    final keys = prefs.getKeys().toList();
    int purgedCount = 0;

    for (final key in keys) {
      String? systemId;
      if (key.startsWith('system_path_')) {
        systemId = key.replaceFirst('system_path_', '');
      } else if (key.startsWith('system_emulator_')) {
        systemId = key.replaceFirst('system_emulator_', '');
      }

      if (systemId != null && !validIds.contains(systemId.toLowerCase())) {
        developer.log(
            'PURGE: Removing orphaned config for unknown system: $systemId',
            name: 'VaultSync',
            level: 800);

        // Get associated path value BEFORE removing the key to clean up SAF permissions
        final pathValue = prefs.getString(key);

        await prefs.remove(key);

        if (pathValue != null) {
          await prefs.remove("saf_uri_$pathValue");
        }
        purgedCount++;
      }
    }

    if (purgedCount > 0) {
      _cachedPaths = null;
      developer.log('PURGE: Cleaned up $purgedCount orphaned settings',
          name: 'VaultSync', level: 800);
    }
  }

  Future<List<Map<String, dynamic>>> _listEntities(String path) async {
    if (Platform.isAndroid) {
      try {
        final String? jsonStr =
            await _platform.invokeMethod('listLibraryNative', {'uri': path});
        if (jsonStr != null) {
          final List<dynamic> list = json.decode(jsonStr);
          return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (e) {
        developer.log('PATH: Native list failed for $path',
            name: 'VaultSync', level: 900, error: e);
      }
      return [];
    }

    final dir = Directory(path);
    if (!dir.existsSync()) return [];

    return dir
        .listSync()
        .map((e) => {
              'name': p.basename(e.path),
              'isDirectory': e is Directory,
              'uri': e.path
            })
        .toList();
  }

  /// Whether [path] resolves to an existing directory on this device.
  ///
  /// On Android this goes through the native `checkPathExists`, which can see
  /// inside `/Android/data` — `dart:io` throws `PathAccessException` there (see
  /// [_dirExistsSafe]). Used to verify auto-suggested save paths instead of
  /// trusting them, since [suggestSavePath] falls back to a hardcoded default
  /// for any system missing from `standaloneDefaults`.
  Future<bool> pathExists(String path) => _checkExists(path);

  Future<bool> _checkExists(String path, {bool isDirectory = true}) async {
    if (Platform.isAndroid) {
      try {
        return await _platform
                .invokeMethod<bool>('checkPathExists', {'uri': path}) ??
            false;
      } catch (_) {
        return false;
      }
    }
    if (isDirectory) return Directory(path).existsSync();
    return File(path).existsSync();
  }

  /// Returns the configured path for a specific `systemId`.
  Future<String?> getSystemPath(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    String? path = prefs.getString('system_path_$systemId');

    // Proactive Auto-Correction & Migration
    if (path != null) {
      final sid = systemId.toLowerCase();

      // 1. Force 3DS into the cleaner 'saves' folder if it's pointing to the root
      // Only for POSIX paths to avoid corrupting SAF URIs.
      if ((sid == '3ds' || sid == 'azahar') &&
          !path.contains('content://') &&
          (path.endsWith('Azahar') || path.endsWith('Azahar/'))) {
        developer.log('PATH: Auto-correcting 3DS path to include /saves',
            name: 'VaultSync', level: 800);
        path = p.join(path, 'saves');
        await setSystemPath(systemId, path);
      }

      // 2. Pull PS2 back to the 'files' root if it was previously set to files/memcards,
      // so that sstates are also included in the scan.
      if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2') {
        if (path.endsWith('/memcards') || path.endsWith('\\memcards')) {
          developer.log(
              'PATH: Auto-migrating PS2 path from /memcards to /files root',
              name: 'VaultSync',
              level: 800);
          path = path.substring(
              0,
              path.lastIndexOf(
                  path.contains('\\') ? '\\memcards' : '/memcards'));
          await setSystemPath(systemId, path);
        }
      }

      // 3. Pull Switch/Eden back to the 'files' root if it's too deep
      if (sid == 'switch' || sid == 'eden') {
        if (path.endsWith('nand/user/save')) {
          developer.log(
              'PATH: Auto-migrating Switch POSIX path from /save to /files',
              name: 'VaultSync',
              level: 800);
          path = path.substring(0, path.lastIndexOf('/nand/user/save'));
          await setSystemPath(systemId, path);
        } else if (path.contains('nand%2Fuser%2Fsave')) {
          developer.log(
              'PATH: Auto-migrating Switch SAF path from /save to /files',
              name: 'VaultSync',
              level: 800);
          path = path.split('nand%2Fuser%2Fsave').first;
          if (path.endsWith('%2F')) path = path.substring(0, path.length - 3);
          await setSystemPath(systemId, path);
        } else if (!path.startsWith('content://')) {
          // Walk DOWN into /files if the user pointed at the emulator package
          // dir. Mirrors Argosy's SwitchSaveHandler.resolveOverrideSaveBase.
          final walked = await resolveSwitchPackageRootPosix(path);
          if (walked != path) {
            developer.log(
                'PATH: Auto-walking Switch path into /files: $path → $walked',
                name: 'VaultSync',
                level: 800);
            path = walked;
            await setSystemPath(systemId, path);
          }
        }
      }
    }

    return path;
  }

  /// Persists a custom save path for a given `systemId`.
  Future<void> setSystemPath(String systemId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("system_path_$systemId", path);
    _cachedPaths = null;
    await prefs.setInt(
        "storage_version", (prefs.getInt("storage_version") ?? 0) + 1);
  }

  /// Returns the systemIds whose currently configured path equals or overlaps
  /// (parent/child) with [candidatePath]. Used by setup UI to warn the user
  /// before two systems end up sharing one local directory — the historical
  /// source of cross-namespace cloud duplication (gc/ ≡ nds/ ≡ ps1/ on the server).
  ///
  /// The system being edited is excluded so re-saving the same value never warns.
  /// Returns an empty list when the path is safe to use.
  Future<List<String>> findPathConflicts(
      String systemId, String candidatePath) async {
    final candidate = _normalizeForOverlap(candidatePath);
    if (candidate.isEmpty) return const [];

    final all = await getAllSystemPaths();
    final conflicts = <String>[];
    for (final entry in all.entries) {
      if (entry.key.toLowerCase() == systemId.toLowerCase()) continue;
      final other = _normalizeForOverlap(entry.value);
      if (other.isEmpty) continue;
      if (_pathsOverlap(candidate, other)) {
        conflicts.add(entry.key);
      }
    }
    return conflicts;
  }

  String _normalizeForOverlap(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  bool _pathsOverlap(String a, String b) {
    if (a == b) return true;
    // Use the '/' separator to avoid '/foo' matching '/foobar'.
    return a.startsWith('$b/') || b.startsWith('$a/');
  }

  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_emulator_$systemId');
  }

  Future<void> setSystemEmulator(String systemId, String emulatorId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("system_emulator_$systemId", emulatorId);
    await prefs.setInt(
        "storage_version", (prefs.getInt("storage_version") ?? 0) + 1);
  }

  Future<int> getStorageVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt("storage_version") ?? 0;
  }

  /// Suggests a default save path based on the detected emulator and system ID.
  Future<String> suggestSavePath(EmulatorInfo emulator, String systemId) async {
    await _ensureConfigLoaded();
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) {
      return (await _getEmuDeckConfig(emuDeckSaves, systemId))['path']!;
    }

    if (Platform.isWindows || Platform.isLinux) {
      final Map? standalones = _config?['standaloneDefaults'];
      if (standalones != null) {
        for (final entry in standalones.entries) {
          if (emulator.uniqueId.contains(entry.key)) {
            final desktopPath = await _getDesktopDefault(entry.key, systemId);
            if (desktopPath != null) return desktopPath;
          }
        }
      }
      return '${_getDesktopHome()}/RetroArch/saves';
    }

    // For RetroArch cores on Android, always use the RetroArch saves directory
    if (RegExp(r'\.ra\d*\.').hasMatch(emulator.uniqueId)) {
      return '/storage/emulated/0/RetroArch/saves';
    }

    final Map? standalones = _config?['standaloneDefaults'];
    if (standalones != null) {
      final entries = standalones.entries.toList()
        ..sort((a, b) =>
            (b.key as String).length.compareTo((a.key as String).length));
      for (final entry in entries) {
        if (emulator.uniqueId.contains(entry.key as String)) {
          return entry.value as String;
        }
      }
    }
    return standalones?[systemId.toLowerCase()] ??
        '/storage/emulated/0/RetroArch/saves';
  }

  Future<String> suggestSavePathById(String systemId) async {
    await _ensureConfigLoaded();
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) {
      return (await _getEmuDeckConfig(emuDeckSaves, systemId))['path']!;
    }

    final sid = systemId.toLowerCase();
    if (Platform.isWindows || Platform.isLinux) {
      final desktopPath = await _getDesktopDefault(sid, sid);
      if (desktopPath != null) return desktopPath;

      if (sid == 'psp') {
        final pspPath = await _getDesktopDefault('ppsspp', sid);
        if (pspPath != null) return pspPath;
      }

      return '${_getDesktopHome()}/RetroArch/saves';
    }

    final Map? standalones = _config?['standaloneDefaults'];
    return standalones?[sid] ?? '/storage/emulated/0/RetroArch/saves';
  }

  Future<String?> getLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('rom_library_path');
  }

  Future<void> setLibraryPath(String rawPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rom_library_path', rawPath);

    String? emuDeckSaves;

    final entities = await _listEntities(rawPath);
    final hasRoms = entities.any((e) =>
        e['isDirectory'] == true &&
        e['name'].toString().toLowerCase() == 'roms');
    final hasSaves = entities.any((e) =>
        e['isDirectory'] == true &&
        e['name'].toString().toLowerCase() == 'saves');

    if (hasRoms && hasSaves) {
      emuDeckSaves = entities.firstWhere((e) =>
          e['isDirectory'] == true &&
          e['name'].toString().toLowerCase() == 'saves')['uri'];
    } else {
      // Check if the current path IS the 'roms' folder
      final name = rawPath.endsWith('/')
          ? rawPath
              .substring(0, rawPath.length - 1)
              .split(RegExp(r'[/\\]'))
              .last
          : rawPath.split(RegExp(r'[/\\]')).last;

      if (name.toLowerCase() == 'roms') {
        // We'd need to find the parent's 'saves' folder.
        // It's much simpler to just convert to POSIX to do string manipulation for parent lookup.
        final posix = toPosix(rawPath);
        final parent = p.dirname(posix);
        final parentSaves = p.join(parent, 'saves');
        if (await _checkExists(parentSaves)) {
          // If we have a content URI, returning the POSIX parentSaves is okay as a fallback
          emuDeckSaves = parentSaves;
        }
      }
    }

    if (emuDeckSaves != null) {
      await prefs.setString('emudeck_saves_path', emuDeckSaves);
    } else {
      await prefs.remove('emudeck_saves_path');
    }
  }

  Future<String?> getEmuDeckSavesPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('emudeck_saves_path');
  }

  bool get _isInsideFlatpak =>
      Platform.isLinux && File('/.flatpak-info').existsSync();

  Future<String?> openDirectoryPicker({String? initialUri}) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // Inside Flatpak, the GTK file picker returns portal paths
      // (/run/user/1000/doc/...) which hide sibling directories.
      // Use the host's native dialog via flatpak-spawn instead.
      if (_isInsideFlatpak) {
        return _hostDirectoryPicker(initialUri);
      }
      return await getDirectoryPath(
          initialDirectory: initialUri, confirmButtonText: 'Select Folder');
    }
    try {
      return await _platform
          .invokeMethod('openSafDirectoryPicker', {'initialUri': initialUri});
    } on PlatformException catch (_) {
      return null;
    }
  }

  Future<String?> _hostDirectoryPicker(String? initialDir) async {
    // Try kdialog (KDE / Steam Deck), then zenity (GNOME) as fallback.
    final startDir = initialDir ?? Platform.environment['HOME'] ?? '/';
    for (final cmd in [
      ['kdialog', '--getexistingdirectory', startDir],
      ['zenity', '--file-selection', '--directory', '--filename=$startDir/'],
    ]) {
      final result = await Process.run('flatpak-spawn', ['--host', ...cmd]);
      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty) return path;
      }
    }
    return null;
  }

  /// Whether [path] lives in a scoped-storage location that requires an explicit
  /// SAF grant.
  ///
  /// Only `/Android/data` is restricted; `shizuku://` paths go through the
  /// Shizuku binder and need no grant at all.
  ///
  /// The check runs against [toPosix] on purpose: a tree URI returned by the
  /// picker is percent-encoded (`…/tree/primary%3AAndroid%2Fdata%2F…`), so
  /// testing the raw value for `android/data` never matches and would wrongly
  /// report that no grant is needed.
  static bool safNeededFor(String path) {
    if (path.startsWith('shizuku://')) return false;
    return toPosix(path).toLowerCase().contains('android/data');
  }

  static String _trimTrailingSlashes(String path) {
    var s = path.replaceAll('\\', '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Whether the SAF tree URI [grantedUri] actually covers [requestedPath].
  ///
  /// The folder picker returns whatever the user confirmed, which is not
  /// necessarily what was asked for — it reopens wherever it was last used, so
  /// confirming without navigating silently grants the previous folder. Storing
  /// that blindly is how a grant requested for melonDS ended up pointing at
  /// Dolphin, which made the `nds` system upload Dolphin's entire tree under its
  /// own namespace. The same mistake sent `dc` to the 3DS folder.
  ///
  /// A tree grant covers everything beneath it, so the grant is valid when it
  /// resolves to the requested folder or to one of its ancestors.
  /// Lifts a RetroArch root that was configured one level too deep.
  ///
  /// RetroArch keeps saves and savestates in two sibling folders and the cloud
  /// namespace mirrors that (`RetroArch/saves/…`, `RetroArch/states/…`). A
  /// system rooted at `…/RetroArch/saves` can therefore only ever see half of
  /// its own namespace: `states/` is invisible to the scanner, so savestates
  /// are never backed up, and anything arriving from `states/` has nowhere to
  /// go but into `saves/`. Rooting at `…/RetroArch` makes both halves line up.
  ///
  /// Deliberately narrow: the parent must literally be `RetroArch`, so roots
  /// like `PPSSPP/PSP/SAVEDATA` — where the last segment is meaningful — are
  /// left alone. URIs are returned unchanged; a SAF grant covers one subtree
  /// and cannot be widened by rewriting the string.
  static String liftRetroArchRoot(String path) {
    if (path.isEmpty || path.contains('://')) return path;

    final trimmed = _trimTrailingSlashes(path);
    final parts = trimmed.split('/');
    if (parts.length < 2) return path;

    final leaf = parts.last.toLowerCase();
    if (leaf != 'saves' && leaf != 'states') return path;
    if (parts[parts.length - 2].toLowerCase() != 'retroarch') return path;

    return parts.sublist(0, parts.length - 1).join('/');
  }

  static bool grantCoversPath(String requestedPath, String grantedUri) {
    final granted = _trimTrailingSlashes(toPosix(grantedUri));
    // toPosix returns the input unchanged for a URI it cannot decode; such a
    // grant cannot be checked, so treat it as not covering anything.
    if (granted.isEmpty || granted.startsWith('content://')) return false;
    final requested = _trimTrailingSlashes(toPosix(requestedPath));
    return requested == granted || requested.startsWith('$granted/');
  }

  /// Given a SAF tree URI whose tree document ID is exactly
  /// `primary:Android/data/<package>` — the app's own external-files package
  /// root, with no deeper segment (not already `.../files`, not some other
  /// subfolder, not a child-document URI) — returns the tree URI for the
  /// `<package>/files` subfolder, percent-encoded the same way the app stores
  /// tree URIs elsewhere (see [_buildInitialUri]:
  /// `content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2F<package>%2Ffiles`).
  ///
  /// Returns null for anything else: a non-SAF path, a SAF path from a
  /// different document provider, a tree already at or below `/files`, or a
  /// tree rooted anywhere other than `Android/data` on the `primary` volume.
  ///
  /// This exists because an emulator's save folder is sometimes configured
  /// (via the SAF picker) at the *package* directory
  /// (`.../Android/data/dev.eden.eden_emulator`) instead of its `files`
  /// subfolder where the emulator actually keeps its data. This was first
  /// found on Switch/Eden — the native scan's Switch filter only recognizes
  /// top-level entries like `nand`/`user`/`save`, so `files/` was skipped
  /// entirely when rooted at the package dir — but the same mistake is
  /// possible for any emulator picked at its package root, which is why
  /// [getEffectivePath]'s migration that uses this function applies to every
  /// system, not just Switch/Eden.
  ///
  /// Deliberately parsed by hand (not via [Uri]'s path-segment API) so the
  /// percent-encoding produced matches exactly what the app already persists,
  /// rather than depending on [Uri]'s own (correct, but independently
  /// verified here) encode/decode round-trip.
  @visibleForTesting
  static String? packageRootFilesTreeUri(String uri) {
    const prefix =
        'content://com.android.externalstorage.documents/tree/';
    if (!uri.startsWith(prefix)) return null;

    final encodedDocId = uri.substring(prefix.length);
    // A literal '/' here means there's more after the tree-document segment
    // (e.g. an appended `/document/...` child reference) — not the bare tree
    // URI this function expects.
    if (encodedDocId.isEmpty || encodedDocId.contains('/')) return null;

    final String docId;
    try {
      docId = Uri.decodeComponent(encodedDocId);
    } catch (_) {
      return null;
    }

    final colonIndex = docId.indexOf(':');
    if (colonIndex == -1) return null;
    final volume = docId.substring(0, colonIndex);
    if (volume != 'primary') return null;

    final relPath = docId.substring(colonIndex + 1);
    final relParts = relPath.split('/').where((s) => s.isNotEmpty).toList();
    // Must be exactly Android/data/<package> — no more, no less.
    if (relParts.length != 3) return null;
    if (relParts[0] != 'Android' || relParts[1] != 'data') return null;
    if (relParts[2].isEmpty) return null;

    final newDocId = '$volume:${relParts.join('/')}/files';
    final encodedNewDocId = Uri.encodeComponent(newDocId);
    return '$prefix$encodedNewDocId';
  }

  /// POSIX/`shizuku://`-form counterpart of [packageRootFilesTreeUri]: given a
  /// path whose segments end in exactly `Android/data/<pkg>` — the app's own
  /// external-files package root, with no deeper segment (not already
  /// `.../files`, not some other subfolder) — returns the path for the
  /// `<pkg>/files` subfolder. Returns null for anything else.
  ///
  /// [posixPath] must already be decoded/scheme-stripped (see [toPosix]) —
  /// this only recognizes the plain filesystem-path shape, and returns null
  /// outright for a `content://` value (use [packageRootFilesTreeUri] for
  /// that form instead).
  ///
  /// Unlike [packageRootFilesTreeUri] there is no volume/provider to check —
  /// a POSIX path carries no SAF document-provider metadata — so this is
  /// purely a segment-shape match. The caller is responsible for verifying
  /// the resulting `/files` path actually exists before trusting it (there is
  /// no SAF grant to check here, see [getEffectivePath]'s use of
  /// [checkPathExists]/[pathExists] as the equivalent safety check).
  @visibleForTesting
  static String? packageRootFilesPosixPath(String posixPath) {
    if (posixPath.startsWith('content://')) return null;
    final normalized = _trimTrailingSlashes(posixPath);
    final parts =
        normalized.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) return null;
    if (parts[parts.length - 3] != 'Android' ||
        parts[parts.length - 2] != 'data') {
      return null;
    }
    final pkg = parts.last;
    if (pkg.isEmpty) return null;
    return '$normalized/files';
  }

  /// Whether [effectivePath] — in any of the three forms [getEffectivePath]
  /// can return (POSIX, `shizuku://`, or a SAF tree URI) — is itself an
  /// Android/data package's `files` directory (`.../Android/data/<pkg>/files`),
  /// i.e. the migration TARGET of [packageRootFilesTreeUri] /
  /// [packageRootFilesPosixPath], not the package root itself.
  ///
  /// Used by the sync diff (see [SyncPathResolver.dealiasFilesRootRemoteKeys])
  /// to recognize when a remote-relative path's leading `files/` segment is
  /// just naming this same root a second time — a device that was (or still
  /// is) configured at the bare package root uploads its saves with that
  /// extra segment baked into the cloud path, while a device already rooted
  /// at `.../files` (post-migration, or always was) uploads the identical
  /// relative path without it.
  static bool isPackageFilesDir(String effectivePath) {
    if (effectivePath.startsWith('content://')) {
      const prefix = 'content://com.android.externalstorage.documents/tree/';
      if (!effectivePath.startsWith(prefix)) return false;
      final encodedDocId = effectivePath.substring(prefix.length);
      if (encodedDocId.isEmpty || encodedDocId.contains('/')) return false;
      final String docId;
      try {
        docId = Uri.decodeComponent(encodedDocId);
      } catch (_) {
        return false;
      }
      final colonIndex = docId.indexOf(':');
      if (colonIndex == -1) return false;
      if (docId.substring(0, colonIndex) != 'primary') return false;
      final relPath = docId.substring(colonIndex + 1);
      final relParts = relPath.split('/').where((s) => s.isNotEmpty).toList();
      return relParts.length == 4 &&
          relParts[0] == 'Android' &&
          relParts[1] == 'data' &&
          relParts[2].isNotEmpty &&
          relParts[3] == 'files';
    }
    final posix = toPosix(effectivePath);
    final parts =
        _trimTrailingSlashes(posix).split('/').where((s) => s.isNotEmpty).toList();
    return parts.length >= 4 &&
        parts[parts.length - 4] == 'Android' &&
        parts[parts.length - 3] == 'data' &&
        parts[parts.length - 1] == 'files';
  }

  /// Pure decision for the package-root SAF migration, applicable to any
  /// system (see [packageRootFilesTreeUri] and [getEffectivePath]), separated
  /// out from the async orchestration (persisting the change, logging,
  /// surfacing a warning) so the decision itself — migrate, block, or don't
  /// apply — is unit-testable without Android's real permission APIs.
  @visibleForTesting
  static PackageRootMigrationResult decidePackageRootMigration(
      String rawPath,
      {required bool grantHeld}) {
    final filesUri = packageRootFilesTreeUri(rawPath);
    if (filesUri == null) {
      return const PackageRootMigrationResult(
          PackageRootMigrationOutcome.notApplicable);
    }
    if (grantHeld) {
      return PackageRootMigrationResult(
          PackageRootMigrationOutcome.migrated, filesUri);
    }
    return const PackageRootMigrationResult(
        PackageRootMigrationOutcome.blockedNoGrant);
  }

  /// Ensures a usable SAF grant exists for [path], prompting the user if needed.
  ///
  /// Returns `false` when the folder is restricted and the user dismissed the
  /// picker, so a single cancelled dialog only skips this path instead of
  /// aborting the whole sync run. Also returns `false` when the user confirms a
  /// folder that does not cover [path] — a wrong grant is worse than none,
  /// because the sync silently reads someone else's data.
  Future<bool> ensureSafPermission(String path) async {
    if (!Platform.isAndroid) return true;
    if (!safNeededFor(path)) return true;

    // A stored tree URI already carries its own persisted grant; verify it
    // directly rather than looking for a saf_uri_* mirror that was never written.
    if (path.startsWith('content://')) {
      final hasPermission = await _platform
          .invokeMethod<bool>('checkSafPermission', {'uri': path});
      if (hasPermission == true) return true;
    }

    final prefs = await SharedPreferences.getInstance();
    final posixPath = toPosix(path);
    final persistedUri =
        prefs.getString("saf_uri_$path") ?? prefs.getString("saf_uri_$posixPath");
    if (persistedUri != null) {
      if (!grantCoversPath(posixPath, persistedUri)) {
        developer.log(
            'SAF: Discarding stored grant that does not cover $posixPath: $persistedUri',
            name: 'VaultSync',
            level: 1000);
        await prefs.remove("saf_uri_$path");
        await prefs.remove("saf_uri_$posixPath");
      } else {
        final hasPermission = await _platform
            .invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
        if (hasPermission == true) return true;
      }
    }
    final pickedUri =
        await openDirectoryPicker(initialUri: _buildInitialUri(path));
    if (pickedUri != null) {
      if (!grantCoversPath(posixPath, pickedUri)) {
        developer.log(
            'SAF: Rejected grant for the wrong folder. Asked for $posixPath, got $pickedUri',
            name: 'VaultSync',
            level: 1000);
        return false;
      }
      await prefs.setString("saf_uri_$path", pickedUri);
      return true;
    }
    developer.log('SAF: Permission declined for restricted folder: $path',
        name: 'VaultSync', level: 900);
    return false;
  }

  String? _buildInitialUri(String path) {
    if (path.startsWith('content://')) return path;
    if (path.startsWith('/storage/emulated/0/')) {
      final relPath = path.replaceFirst('/storage/emulated/0/', '');
      return "content://com.android.externalstorage.documents/document/primary%3A${Uri.encodeComponent(relPath)}";
    }
    return null;
  }

  /// Normalises a stored path value to a plain POSIX path.
  ///
  /// Strips the `shizuku://` scheme and decodes SAF tree URIs
  /// (`content://…/tree/primary%3AAndroid%2Fdata%2Fx` →
  /// `/storage/emulated/0/Android/data/x`).
  ///
  /// Returns the input unchanged for a `content://` URI it cannot decode (no
  /// `/tree/` segment, or fewer than two colon-separated parts), so callers that
  /// need a real POSIX path must check for a leftover `content://` prefix.
  @visibleForTesting
  static String toPosix(String path) {
    if (!path.startsWith('content://')) {
      return path.replaceFirst('shizuku://', '');
    }
    final decoded = Uri.decodeComponent(path);
    if (decoded.contains('/tree/')) {
      final treePart = decoded.split('/tree/').last;
      final parts = treePart.split(':');
      if (parts.length >= 2) {
        final volumeId = parts[0].split('/').last;
        final relPath = parts.sublist(1).join(':');
        if (volumeId == 'primary') return '/storage/emulated/0/$relPath';
        return '/storage/$volumeId/$relPath';
      }
    }
    return path;
  }

  Future<bool> _hasValidRoms(String path, List<String> validExtensions) async {
    if (validExtensions.isEmpty) return false;

    if (Platform.isAndroid) {
      try {
        return await _platform.invokeMethod<bool>('hasFilesWithExtensions',
                {'uri': path, 'extensions': validExtensions}) ??
            false;
      } catch (e) {
        developer.log('SCAN: Native extension check failed for $path',
            name: 'VaultSync', level: 900, error: e);
      }
    }

    // Fallback for non-Android or if native fails
    final extSet = validExtensions.map((e) => e.toLowerCase()).toSet();
    try {
      final entities = await _listEntities(path);
      for (final entity in entities) {
        final name = entity['name'].toString().toLowerCase();
        if (entity['isDirectory']) {
          if (await _hasValidRoms(entity['uri'], validExtensions)) return true;
        } else {
          final ext = name.contains('.') ? name.split('.').last : '';
          if (ext.isNotEmpty && extSet.contains(ext)) return true;
        }
      }
    } catch (e) {
      developer.log('SCAN: Error checking ROMs in $path',
          name: 'VaultSync', level: 900, error: e);
    }
    return false;
  }

  Future<Map<String, String>> _getEmuDeckConfig(
      String emuDeckSaves, String systemId) async {
    await _ensureConfigLoaded();
    final base = emuDeckSaves;
    final sid = systemId.toLowerCase();

    Future<String> findFolderAsync(String parent, String target) async {
      try {
        final entities = await _listEntities(parent);
        for (final entity in entities) {
          if (entity['name'].toString().toLowerCase() == target.toLowerCase()) {
            return entity['uri'];
          }
        }
      } catch (e) {
        developer.log('EMUDECK: Error finding folder $target in $parent',
            name: 'VaultSync', level: 900, error: e);
      }
      return p.join(parent, target);
    }

    Future<String> wikiPath(String emulator, {String sub = "saves"}) async {
      final root = await findFolderAsync(base, emulator);
      if (sub.isEmpty) return root;
      return p.join(root, sub);
    }

    final Map? emuMap = _config?['emuMap'];
    final config = emuMap?[sid];

    if (config != null) {
      final emulator = config['emulator'];
      final sub = config['sub'] ?? "saves";

      if (sid == "switch" || sid == "eden") {
        final yuzuRoot = await wikiPath("yuzu", sub: "");
        if (await _checkExists(yuzuRoot)) {
          return {"path": yuzuRoot, "emulatorId": "switch.yuzu.desktop"};
        }
        return {
          "path": await wikiPath("ryujinx", sub: ""),
          "emulatorId": "switch.ryujinx.desktop"
        };
      }

      final mainPath = await wikiPath(emulator, sub: sub);
      if (await _checkExists(mainPath) ||
          (config['retroArchId'] ?? "").isEmpty) {
        return {"path": mainPath, "emulatorId": config['desktopId']};
      }
      return {
        "path": await wikiPath("retroarch"),
        "emulatorId": config['retroArchId']
      };
    }

    final Map? retroArchCores = _config?['retroArchCores'];
    return {
      'path': await wikiPath('retroarch'),
      'emulatorId': retroArchCores?[sid] ?? ''
    };
  }

  /// Resolves the 'effective' path for Android, handling POSIX, SAF, and Shizuku abstraction.
  ///
  /// [onWarning], when supplied, surfaces a user-facing message for a
  /// migration this method could not safely apply on its own (see the
  /// Switch/Eden package-root check below) — every sync entry point that
  /// already has an `onError`-style callback threads it through here as
  /// [onWarning] (see `SyncService._resolveEffectivePaths`).
  Future<String> getEffectivePath(String systemId,
      {void Function(String)? onWarning}) async {
    String? rawPath = await getSystemPath(systemId);
    final emulatorId = await getSystemEmulator(systemId);

    // MIGRATION: If we have a RetroArch core but a standalone path was saved,
    // it's almost certainly a legacy mistake from before the core-aware suggestion fix.
    if (rawPath != null && emulatorId != null && Platform.isAndroid) {
      if (RegExp(r'\.ra\d*\.').hasMatch(emulatorId)) {
        if (rawPath.contains('com.mgba.android') ||
            rawPath.contains('com.github.stenzek.duckstation')) {
          developer.log(
              'PATH: Migrating legacy standalone path for RA core $emulatorId',
              name: 'VaultSync',
              level: 800);
          // The namespace root, not `saves`: see [liftRetroArchRoot].
          rawPath = '/storage/emulated/0/RetroArch';
          // Persist the fix so we don't keep re-migrating
          await setSystemPath(systemId, rawPath);
        }
      }
    }

    // One-time correction for roots stored one level inside RetroArch. Persisted
    // so the UI, the badges and the sync journal all agree on the same root.
    if (rawPath != null) {
      final lifted = liftRetroArchRoot(rawPath);
      if (lifted != rawPath) {
        developer.log(
            'PATH: Lifting $systemId from "$rawPath" to "$lifted" so saves/ and states/ both resolve',
            name: 'VaultSync',
            level: 900);
        rawPath = lifted;
        await setSystemPath(systemId, rawPath);
      }
    }

    if (rawPath == null) return await suggestSavePathById(systemId);
    if (!Platform.isAndroid) return rawPath;

    final prefs = await SharedPreferences.getInstance();
    final useShizuku = prefs.getBool('use_shizuku') ?? false;

    var posixPath = toPosix(rawPath);

    // Package-root -> /files migration for the POSIX and `shizuku://` forms of
    // the same path (the non-SAF counterpart of the content:// migration
    // below, generalized the same way — see that block's comment for why the
    // switch/eden restriction was dropped). A value stored in system_path_*
    // is always plain POSIX or content:// (every setSystemPath call site
    // writes one of those two — see its call sites); the `shizuku://` scheme
    // is only ever applied transiently below based on the use_shizuku toggle,
    // never persisted. So only the POSIX form needs handling here, but it
    // must run BEFORE the useShizuku early-return just below, otherwise a
    // package root configured while Shizuku is enabled would be wrapped in
    // `shizuku://` and returned before ever reaching this check.
    //
    // There is no SAF "grant" to verify for either transport — a POSIX path
    // is either accessible or it isn't, and Shizuku reads through the shell —
    // so [checkPathExists] (via [_checkExists]) on the candidate `/files`
    // directory, probed through whichever transport this call would
    // otherwise use, is the closest available safety check: migrate only if
    // that directory demonstrably exists, exactly as suggested by the task
    // (`.../Android/data/<pkg>` -> `.../Android/data/<pkg>/files` when that
    // dir exists via checkPathExists). Otherwise leave the path as-is and
    // warn, mirroring the SAF branch's blockedNoGrant outcome.
    if (!rawPath.startsWith('content://')) {
      final candidateFilesPosix = packageRootFilesPosixPath(posixPath);
      if (candidateFilesPosix != null) {
        final probeUri =
            useShizuku ? 'shizuku://$candidateFilesPosix' : candidateFilesPosix;
        final filesExists = await _checkExists(probeUri);
        if (filesExists) {
          developer.log(
              'PATH: Migrating $systemId from package root to /files: $posixPath -> $candidateFilesPosix',
              name: 'VaultSync',
              level: 800);
          rawPath = candidateFilesPosix;
          posixPath = candidateFilesPosix;
          await setSystemPath(systemId, rawPath);
        } else {
          developer.log(
              'PATH: $systemId path is rooted at the Android/data package dir, '
              'not its files/ subfolder, but that subfolder could not be found — '
              'leaving the path as-is rather than guessing. A stray copy outside '
              'files/ may get synced instead of the real save tree.',
              name: 'VaultSync',
              level: 900);
          onWarning?.call(
              'VaultSync needs the "files" folder inside the $systemId '
              'emulator\'s data directory to sync correctly, but it could not '
              'be found. Open the emulator once to create it, or re-select the '
              'save folder in Settings.');
        }
      }
    }

    if (useShizuku && posixPath.startsWith('/storage/emulated/0/')) {
      return 'shizuku://$posixPath';
    }

    if (posixPath.toLowerCase().contains('android/data')) {
      if (rawPath.startsWith('content://')) {
        // Generalized to every system, not just switch/eden: any system whose
        // configured SAF tree is exactly an Android/data package root (see
        // packageRootFilesTreeUri) can suffer the same problem — the native
        // scanner only ever sees what's directly granted, so a root at the
        // package dir instead of its files/ subfolder silently hides
        // everything an emulator actually keeps saves in.
        final candidateFilesUri = packageRootFilesTreeUri(rawPath);
        if (candidateFilesUri != null) {
          // Same check used elsewhere in this file to verify a persisted
          // SAF grant is still actually held before trusting it (see the
          // reinstall-drops-grants handling further down) — reused here
          // rather than guessing that a /files grant exists.
          final grantHeld = await _platform.invokeMethod<bool>(
                  'checkSafPermission', {'uri': candidateFilesUri}) ==
              true;
          final decision =
              decidePackageRootMigration(rawPath, grantHeld: grantHeld);
          switch (decision.outcome) {
            case PackageRootMigrationOutcome.migrated:
              final migratedPath = decision.migratedPath!;
              developer.log(
                  'PATH: Migrating $systemId SAF grant from package root to /files: $rawPath -> $migratedPath',
                  name: 'VaultSync',
                  level: 800);
              rawPath = migratedPath;
              await setSystemPath(systemId, rawPath);
              return rawPath;
            case PackageRootMigrationOutcome.blockedNoGrant:
              developer.log(
                  'PATH: $systemId SAF path is rooted at the Android/data package '
                  'dir, not its files/ subfolder, but no SAF grant is held for '
                  'files/ — leaving the path as-is rather than guessing. A stray '
                  'copy outside files/ may get synced instead of the real save tree.',
                  name: 'VaultSync',
                  level: 900);
              onWarning?.call(
                  'VaultSync needs access to the "files" folder inside the '
                  '$systemId emulator\'s data directory to sync correctly. '
                  'Please re-select the save folder in Settings.');
              break;
            case PackageRootMigrationOutcome.notApplicable:
              break;
          }
        }
        developer.log('PATH: Using SAF effective path for $systemId: $rawPath',
            name: 'VaultSync', level: 800);
        return rawPath;
      }
      final persistedUri = prefs.getString("saf_uri_$posixPath");
      if (persistedUri != null) {
        // A grant pointing somewhere else would make this system read another
        // emulator's folder and upload it under this system's namespace, so
        // fall back to POSIX rather than trust it.
        if (!grantCoversPath(posixPath, persistedUri)) {
          developer.log(
              'PATH: Ignoring SAF grant for $systemId — it points outside $posixPath: $persistedUri',
              name: 'VaultSync',
              level: 1000);
          await prefs.remove("saf_uri_$posixPath");
          return rawPath;
        }
        // Covering the path is not enough — the grant also has to still exist.
        // Reinstalling the APK drops every persisted URI permission while this
        // mirror survives in prefs, so the app went on handing out a
        // content:// URI it no longer held and every write failed with EACCES,
        // once per file. Dropping the stale entry falls back to POSIX and lets
        // ensureSafPermission ask for the folder again.
        final stillGranted = await _platform
            .invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
        if (stillGranted != true) {
          developer.log(
              'PATH: Persisted SAF grant for $systemId is no longer held (reinstall?) — discarding: $persistedUri',
              name: 'VaultSync',
              level: 1000);
          await prefs.remove("saf_uri_$posixPath");
          return rawPath;
        }
        developer.log(
            'PATH: Using persisted SAF URI for $systemId: $persistedUri',
            name: 'VaultSync',
            level: 800);
        return persistedUri;
      }
      developer.log('PATH: Falling back to POSIX for $systemId: $posixPath',
          name: 'VaultSync', level: 800);
      return rawPath;
    }

    developer.log('PATH: Using POSIX effective path for $systemId: $posixPath',
        name: 'VaultSync', level: 800);
    return posixPath;
  }

  /// Automatically scans a ROM library to detect systems and their save locations.
  Future<List<Map<String, String>>> scanLibrary(String inputPath) async {
    final results = <Map<String, String>>[];
    try {
      final String path = inputPath;
      developer.log('SCAN: Starting library scan for path: $path',
          name: 'VaultSync', level: 800);
      final exists = await _checkExists(path);
      developer.log('SCAN: Path exists: $exists',
          name: 'VaultSync', level: 800);

      if (!exists) {
        return [];
      }

      String romsDir = path;
      String? emuDeckSaves;

      final entities = await _listEntities(path);
      developer.log('SCAN: Found ${entities.length} entities in root folder.',
          name: 'VaultSync', level: 800);

      final hasRoms = entities.any((e) =>
          e['isDirectory'] == true &&
          e['name'].toString().toLowerCase() == 'roms');
      final hasSaves = entities.any((e) =>
          e['isDirectory'] == true &&
          e['name'].toString().toLowerCase() == 'saves');

      if (hasRoms && hasSaves) {
        romsDir = entities.firstWhere((e) =>
            e['isDirectory'] == true &&
            e['name'].toString().toLowerCase() == 'roms')['uri'];
        emuDeckSaves = entities.firstWhere((e) =>
            e['isDirectory'] == true &&
            e['name'].toString().toLowerCase() == 'saves')['uri'];
      } else {
        final name = path.endsWith('/')
            ? path.substring(0, path.length - 1).split(RegExp(r'[/\\]')).last
            : path.split(RegExp(r'[/\\]')).last;

        if (name.toLowerCase() == 'roms') {
          final posix = toPosix(path);
          final parent = p.dirname(posix);
          final parentSaves = p.join(parent, 'saves');
          if (await _checkExists(parentSaves)) {
            emuDeckSaves = parentSaves;
          }
        }
      }

      developer.log(
          'SCAN: Resolved romsDir: $romsDir, emuDeckSaves: $emuDeckSaves',
          name: 'VaultSync',
          level: 800);

      final systems = await _emulatorRepository.loadSystems();
      final list = await _listEntities(romsDir);
      developer.log('SCAN: Found ${list.length} entities in romsDir.',
          name: 'VaultSync', level: 800);

      for (final system in systems) {
        final matchingDirs =
            list.where((e) => e['isDirectory'] == true).where((e) {
          final name = e['name'].toString().toLowerCase();
          return name == system.system.id.toLowerCase() ||
              name == system.system.name.toLowerCase() ||
              system.system.folders.map((f) => f.toLowerCase()).contains(name);
        });

        for (final d in matchingDirs) {
          final dirPath = d['uri'];
          if (await _hasValidRoms(dirPath, system.system.extensions)) {
            if (emuDeckSaves != null) {
              final config =
                  await _getEmuDeckConfig(emuDeckSaves, system.system.id);
              results.add({
                'systemId': system.system.id,
                'path': config['path']!,
                'emulatorId': config['emulatorId']!
              });
            } else {
              results.add({'systemId': system.system.id});
            }
          }
        }
      }
    } catch (e) {
      developer.log('SCAN: Library scan failed',
          name: 'VaultSync', level: 900, error: e);
    }
    await logConfiguredPaths();
    return results;
  }

  Future<void> logConfiguredPaths() async {
    final paths = await getAllSystemPaths();
    final prefs = await SharedPreferences.getInstance();
    final buf = StringBuffer('CONFIG DUMP:\n');
    for (final entry in paths.entries) {
      final emu = prefs.getString("system_emulator_${entry.key}");
      buf.writeln(
          '  ${entry.key.toUpperCase()}: path=${entry.value}, core=${emu ?? "NOT SET"}');
    }
    developer.log(buf.toString().trimRight(), name: 'VaultSync', level: 800);
  }

  Future<bool> mkdirs(String path) async {
    if (!Platform.isAndroid) {
      await Directory(path).create(recursive: true);
      return true;
    }
    try {
      return await _platform.invokeMethod<bool>('mkdirs', {'path': path}) ??
          false;
    } catch (e) {
      developer.log('PATH: mkdirs failed for $path',
          name: 'VaultSync', level: 900, error: e);
      return false;
    }
  }

  Future<String?> getSwitchSavePathForGame(
          String systemId, String gameId) async =>
      await getEffectivePath(systemId);

  /// Probes the Switch/Eden emulator NAND directory to discover the user's profile ID.
  /// Used for first-restore scenarios where no local save files exist yet to probe from.
  Future<String?> probeProfileId(String effectivePath) async {
    if (!Platform.isAndroid) return null;

    // Use native probing for all Android paths (SAF and Shizuku)
    // because Dart I/O cannot see inside /Android/data.
    try {
      // 1. Try to read the real ID from Eden's profiles.dat first
      final edenId = await _platform
          .invokeMethod<String?>('readEdenUserId', {'uri': effectivePath});
      if (edenId != null) {
        developer.log('EDEN: Discovered real User ID via profiles.dat: $edenId',
            name: 'VaultSync', level: 800);
        return edenId;
      }

      // 2. Fallback to general Switch profile discovery
      return await _platform
          .invokeMethod<String?>('findSwitchProfileId', {'uri': effectivePath});
    } catch (e) {
      developer.log('PROBE: Native profile discovery failed',
          name: 'VaultSync', level: 900, error: e);
    }

    // Fallback for simple non-restricted POSIX paths (SD card, etc)
    final posixPath = effectivePath.replaceFirst('shizuku://', '');
    String basePath = posixPath;
    if (basePath.contains('nand/user/save')) {
      basePath = basePath.substring(0, basePath.indexOf('nand/user/save'));
    }

    for (final base in [
      '$basePath/nand/user/save/0000000000000000',
      '$basePath/files/nand/user/save/0000000000000000'
    ]) {
      final picked = await pickActiveProfileFromZeroUserDir(Directory(base));
      if (picked != null) return picked;
    }
    return null;
  }

  /// Walks DOWN a user-supplied Switch/Eden POSIX path to find the "files
  /// root" (the directory one level above `nand/user/save`). Returns the
  /// original path unchanged if no walk is needed or nothing matches.
  ///
  /// Mirrors the walk-down half of Argosy's
  /// `SwitchSaveHandler.resolveOverrideSaveBase`.
  ///
  /// Uses plain `dart:io` probes, which cannot see inside `/Android/data` on
  /// Android 13+ — a raw `Directory.exists()` there throws
  /// `PathAccessException` (errno 13) rather than returning false. Those probes
  /// are wrapped so the walk degrades to "return unchanged" instead of throwing:
  /// for restricted paths the effective-path resolution and native/Shizuku
  /// layer handle the real I/O downstream.
  static Future<String> resolveSwitchPackageRootPosix(String path) async {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;

    // If the path already is the files root, leave it alone.
    if (await _dirExistsSafe('$normalized/nand/user/save')) {
      return normalized;
    }
    // If the path is the package dir (one above files root), walk down.
    if (await _dirExistsSafe('$normalized/files/nand/user/save')) {
      return '$normalized/files';
    }
    return normalized;
  }

  /// `Directory.exists()` that never throws. On Android 13+ probing a
  /// `/Android/data` path throws `PathAccessException` instead of returning
  /// false; treat any error as "not accessible via dart:io" (false).
  static Future<bool> _dirExistsSafe(String path) async {
    try {
      return await Directory(path).exists();
    } catch (e) {
      developer.log('PATH: dart:io probe blocked for $path (treating as absent)',
          name: 'VaultSync', level: 800, error: e);
      return false;
    }
  }

  /// Picks the active Switch profile ID from a `0000000000000000` directory.
  ///
  /// Mirrors Argosy's `SwitchSaveHandler.findActiveProfileFolder` mtime
  /// fallback: if exactly one non-zero profile exists, it wins; otherwise the
  /// one with the most-recently-touched subtree is picked. Exposed at
  /// library-level for unit testing.
  static Future<String?> pickActiveProfileFromZeroUserDir(
      Directory zeroUserDir) async {
    // `.exists()` throws PathAccessException on /Android/data (Android 13+),
    // so guard it the same way as the walk probes.
    if (!await _dirExistsSafe(zeroUserDir.path)) return null;

    final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
    final candidates = <Directory>[];
    try {
      await for (final entity in zeroUserDir.list()) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          if (profileRegex.hasMatch(name) &&
              name != '00000000000000000000000000000000') {
            candidates.add(entity);
          }
        }
      }
    } catch (_) {
      return null;
    }
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first.path.split('/').last;

    var best = candidates.first;
    var bestMtime = await _newestMtimeUnder(best);
    for (var i = 1; i < candidates.length; i++) {
      final m = await _newestMtimeUnder(candidates[i]);
      if (m > bestMtime) {
        bestMtime = m;
        best = candidates[i];
      }
    }
    return best.path.split('/').last;
  }

  static Future<int> _newestMtimeUnder(Directory dir) async {
    var newest = 0;
    try {
      newest = (await dir.stat()).modified.millisecondsSinceEpoch;
    } catch (_) {}
    try {
      await for (final e in dir.list(recursive: true)) {
        try {
          final m = (await e.stat()).modified.millisecondsSinceEpoch;
          if (m > newest) newest = m;
        } catch (_) {}
      }
    } catch (_) {}
    return newest;
  }

  Future<Map<String, String>> getRetroArchPaths() async {
    final saves = await getSystemPath('retroarch') ??
        await suggestSavePathById('retroarch');
    final states = (saves.endsWith('/saves'))
        ? '${saves.substring(0, saves.length - 6)}/states'
        : '$saves/states';
    return {'saves': saves, 'states': states};
  }
}
