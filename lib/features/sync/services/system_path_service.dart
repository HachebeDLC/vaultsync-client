import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
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
      final jsonStr = await rootBundle.loadString('assets/config/path_config.json');
      _config = json.decode(jsonStr);
    } catch (e) {
      developer.log('CONFIG: Failed to load path_config.json', name: 'VaultSync', level: 900, error: e);
      _config = {};
    }
  }

  String _getDesktopHome() {
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
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
        developer.log('PURGE: Removing orphaned config for unknown system: $systemId', name: 'VaultSync', level: 800);
        
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
      developer.log('PURGE: Cleaned up $purgedCount orphaned settings', name: 'VaultSync', level: 800);
    }
  }

  Future<List<Map<String, dynamic>>> _listEntities(String path) async {
    if (Platform.isAndroid) {
      try {
        final String? jsonStr = await _platform.invokeMethod('listLibraryNative', {'uri': path});
        if (jsonStr != null) {
          final List<dynamic> list = json.decode(jsonStr);
          return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (e) {
        developer.log('PATH: Native list failed for $path', name: 'VaultSync', level: 900, error: e);
      }
      return [];
    }
    
    final dir = Directory(path);
    if (!dir.existsSync()) return [];
    
    return dir.listSync().map((e) => {
      'name': p.basename(e.path),
      'isDirectory': e is Directory,
      'uri': e.path
    }).toList();
  }

  Future<bool> _checkExists(String path, {bool isDirectory = true}) async {
    if (Platform.isAndroid) {
      try {
        return await _platform.invokeMethod<bool>('checkPathExists', {'uri': path}) ?? false;
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
      if ((sid == '3ds' || sid == 'azahar') && !path.contains('content://') && (path.endsWith('Azahar') || path.endsWith('Azahar/'))) {
        developer.log('PATH: Auto-correcting 3DS path to include /saves', name: 'VaultSync', level: 800);
        path = p.join(path, 'saves');
        await setSystemPath(systemId, path);
      }

      // 2. Pull PS2 back to the 'files' root if it was previously set to files/memcards,
      // so that sstates are also included in the scan.
      if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2') {
        if (path.endsWith('/memcards') || path.endsWith('\\memcards')) {
          developer.log('PATH: Auto-migrating PS2 path from /memcards to /files root', name: 'VaultSync', level: 800);
          path = path.substring(0, path.lastIndexOf(path.contains('\\') ? '\\memcards' : '/memcards'));
          await setSystemPath(systemId, path);
        }
      }

      // 3. Pull Switch/Eden back to the 'files' root if it's too deep
      if (sid == 'switch' || sid == 'eden') {
        if (path.endsWith('nand/user/save')) {
           developer.log('PATH: Auto-migrating Switch POSIX path from /save to /files', name: 'VaultSync', level: 800);
           path = path.substring(0, path.lastIndexOf('/nand/user/save'));
           await setSystemPath(systemId, path);
        } else if (path.contains('nand%2Fuser%2Fsave')) {
           developer.log('PATH: Auto-migrating Switch SAF path from /save to /files', name: 'VaultSync', level: 800);
           path = path.split('nand%2Fuser%2Fsave').first;
           if (path.endsWith('%2F')) path = path.substring(0, path.length - 3);
           await setSystemPath(systemId, path);
        } else if (!path.startsWith('content://')) {
          // Walk DOWN into /files if the user pointed at the emulator package
          // dir. Mirrors Argosy's SwitchSaveHandler.resolveOverrideSaveBase.
          final walked = await resolveSwitchPackageRootPosix(path);
          if (walked != path) {
            developer.log('PATH: Auto-walking Switch path into /files: $path → $walked', name: 'VaultSync', level: 800);
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
    await prefs.setInt("storage_version", (prefs.getInt("storage_version") ?? 0) + 1);
  }

  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_emulator_$systemId');
  }

  Future<void> setSystemEmulator(String systemId, String emulatorId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("system_emulator_$systemId", emulatorId);
    await prefs.setInt("storage_version", (prefs.getInt("storage_version") ?? 0) + 1);
  }

  Future<int> getStorageVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt("storage_version") ?? 0;
  }

  /// Suggests a default save path based on the detected emulator and system ID.
  Future<String> suggestSavePath(EmulatorInfo emulator, String systemId) async {
    await _ensureConfigLoaded();
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) return (await _getEmuDeckConfig(emuDeckSaves, systemId))['path']!;
    
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
      for (final entry in standalones.entries) {
        if (emulator.uniqueId.contains(entry.key as String)) {
          return entry.value as String;
        }
      }
    }
    return standalones?[systemId.toLowerCase()] ?? '/storage/emulated/0/RetroArch/saves';
  }

  Future<String> suggestSavePathById(String systemId) async {
    await _ensureConfigLoaded();
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) return (await _getEmuDeckConfig(emuDeckSaves, systemId))['path']!;
    
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
    final hasRoms = entities.any((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'roms');
    final hasSaves = entities.any((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'saves');
    
    if (hasRoms && hasSaves) {
      emuDeckSaves = entities.firstWhere((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'saves')['uri'];
    } else {
      // Check if the current path IS the 'roms' folder
      final name = rawPath.endsWith('/') 
          ? rawPath.substring(0, rawPath.length - 1).split(RegExp(r'[/\\]')).last 
          : rawPath.split(RegExp(r'[/\\]')).last;
          
      if (name.toLowerCase() == 'roms') {
        // We'd need to find the parent's 'saves' folder.
        // It's much simpler to just convert to POSIX to do string manipulation for parent lookup.
        final posix = _convertToPosix(rawPath);
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

  bool get _isInsideFlatpak => Platform.isLinux && File('/.flatpak-info').existsSync();

  Future<String?> openDirectoryPicker({String? initialUri}) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // Inside Flatpak, the GTK file picker returns portal paths
      // (/run/user/1000/doc/...) which hide sibling directories.
      // Use the host's native dialog via flatpak-spawn instead.
      if (_isInsideFlatpak) {
          return _hostDirectoryPicker(initialUri);
      }
      return await getDirectoryPath(initialDirectory: initialUri, confirmButtonText: 'Select Folder');
    }
    try { return await _platform.invokeMethod('openSafDirectoryPicker', {'initialUri': initialUri}); }
    on PlatformException catch (_) { return null; }
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

  Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;
    try { return await _platform.invokeMethod<int>("getAndroidVersion") ?? 0; }
    catch (_) { return 0; }
  }

  Future<bool> ensureSafPermission(String path) async {
    if (!Platform.isAndroid) return true;
    if (path.startsWith('shizuku://')) return true;
    if (!path.toLowerCase().contains('android/data')) return true;
    final prefs = await SharedPreferences.getInstance();
    final persistedUri = prefs.getString("saf_uri_$path");
    if (persistedUri != null) {
      final hasPermission = await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
      if (hasPermission == true) return true;
    }
    final pickedUri = await openDirectoryPicker(initialUri: _buildInitialUri(path));
    if (pickedUri != null) { await prefs.setString("saf_uri_$path", pickedUri); return true; }
    throw Exception("SAF Permission required for restricted folder: $path");
  }

  String? _buildInitialUri(String path) {
    if (path.startsWith('content://')) return path;
    if (path.startsWith('/storage/emulated/0/')) {
      final relPath = path.replaceFirst('/storage/emulated/0/', '');
      return "content://com.android.externalstorage.documents/document/primary%3A${Uri.encodeComponent(relPath)}";
    }
    return null;
  }

  String _convertToPosix(String path) {
    if (!path.startsWith('content://')) return path.replaceFirst('shizuku://', '');
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
        return await _platform.invokeMethod<bool>('hasFilesWithExtensions', {
          'uri': path,
          'extensions': validExtensions
        }) ?? false;
      } catch (e) {
        developer.log('SCAN: Native extension check failed for $path', name: 'VaultSync', level: 900, error: e);
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
      developer.log('SCAN: Error checking ROMs in $path', name: 'VaultSync', level: 900, error: e);
    }
    return false;
  }

  Future<Map<String, String>> _getEmuDeckConfig(String emuDeckSaves, String systemId) async {
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
        developer.log('EMUDECK: Error finding folder $target in $parent', name: 'VaultSync', level: 900, error: e);
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
        if (await _checkExists(yuzuRoot)) return { "path": yuzuRoot, "emulatorId": "switch.yuzu.desktop" };
        return { "path": await wikiPath("ryujinx", sub: ""), "emulatorId": "switch.ryujinx.desktop" };
      }
      
      final mainPath = await wikiPath(emulator, sub: sub);
      if (await _checkExists(mainPath) || (config['retroArchId'] ?? "").isEmpty) {
        return { "path": mainPath, "emulatorId": config['desktopId'] };
      }
      return { "path": await wikiPath("retroarch"), "emulatorId": config['retroArchId'] };
    }

    final Map? retroArchCores = _config?['retroArchCores'];
    return { 'path': await wikiPath('retroarch'), 'emulatorId': retroArchCores?[sid] ?? '' };
  }

  /// Resolves the 'effective' path for Android, handling POSIX, SAF, and Shizuku abstraction.
  Future<String> getEffectivePath(String systemId) async {
    String? rawPath = await getSystemPath(systemId);
    final emulatorId = await getSystemEmulator(systemId);

    // MIGRATION: If we have a RetroArch core but a standalone path was saved,
    // it's almost certainly a legacy mistake from before the core-aware suggestion fix.
    if (rawPath != null && emulatorId != null && Platform.isAndroid) {
      if (RegExp(r'\.ra\d*\.').hasMatch(emulatorId)) {
        if (rawPath.contains('com.mgba.android') || rawPath.contains('com.github.stenzek.duckstation')) {
          developer.log('PATH: Migrating legacy standalone path for RA core $emulatorId', name: 'VaultSync', level: 800);
          rawPath = '/storage/emulated/0/RetroArch/saves';
          // Persist the fix so we don't keep re-migrating
          await setSystemPath(systemId, rawPath);
        }
      }
    }

    if (rawPath == null) return await suggestSavePathById(systemId);
    if (!Platform.isAndroid) return rawPath;

    final prefs = await SharedPreferences.getInstance();
    final useShizuku = prefs.getBool('use_shizuku') ?? false;

    final posixPath = _convertToPosix(rawPath);

    if (useShizuku && posixPath.startsWith('/storage/emulated/0/')) {
       return 'shizuku://$posixPath';
    }

    if (posixPath.toLowerCase().contains('android/data')) {
       if (rawPath.startsWith('content://')) {
          developer.log('PATH: Using SAF effective path for $systemId: $rawPath', name: 'VaultSync', level: 800);
          return rawPath;
       }
       final persistedUri = prefs.getString("saf_uri_$posixPath");
       if (persistedUri != null) {
          developer.log('PATH: Using persisted SAF URI for $systemId: $persistedUri', name: 'VaultSync', level: 800);
          return persistedUri;
       }
       developer.log('PATH: Falling back to POSIX for $systemId: $posixPath', name: 'VaultSync', level: 800);
       return rawPath; 
    }
    
    developer.log('PATH: Using POSIX effective path for $systemId: $posixPath', name: 'VaultSync', level: 800);
    return posixPath;
  }

  /// Automatically scans a ROM library to detect systems and their save locations.
  Future<List<Map<String, String>>> scanLibrary(String inputPath) async {
    final results = <Map<String, String>>[];
    try {
      final String path = inputPath;
      developer.log('SCAN: Starting library scan for path: $path', name: 'VaultSync', level: 800);
      final exists = await _checkExists(path);
      developer.log('SCAN: Path exists: $exists', name: 'VaultSync', level: 800);
      
      if (!exists) {
        return [];
      }
      
      String romsDir = path;
      String? emuDeckSaves;

      final entities = await _listEntities(path);
      developer.log('SCAN: Found ${entities.length} entities in root folder.', name: 'VaultSync', level: 800);
      
      final hasRoms = entities.any((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'roms');
      final hasSaves = entities.any((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'saves');

      if (hasRoms && hasSaves) {
        romsDir = entities.firstWhere((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'roms')['uri'];
        emuDeckSaves = entities.firstWhere((e) => e['isDirectory'] == true && e['name'].toString().toLowerCase() == 'saves')['uri'];
      } else {
        final name = path.endsWith('/') 
            ? path.substring(0, path.length - 1).split(RegExp(r'[/\\]')).last 
            : path.split(RegExp(r'[/\\]')).last;
            
        if (name.toLowerCase() == 'roms') {
          final posix = _convertToPosix(path);
          final parent = p.dirname(posix);
          final parentSaves = p.join(parent, 'saves');
          if (await _checkExists(parentSaves)) {
            emuDeckSaves = parentSaves;
          }
        }
      }

      developer.log('SCAN: Resolved romsDir: $romsDir, emuDeckSaves: $emuDeckSaves', name: 'VaultSync', level: 800);

      final systems = await _emulatorRepository.loadSystems();
      final list = await _listEntities(romsDir);
      developer.log('SCAN: Found ${list.length} entities in romsDir.', name: 'VaultSync', level: 800);
      
      for (final system in systems) {
        final matchingDirs = list.where((e) => e['isDirectory'] == true).where((e) {
          final name = e['name'].toString().toLowerCase();
          return name == system.system.id.toLowerCase() || 
                 name == system.system.name.toLowerCase() || 
                 system.system.folders.map((f) => f.toLowerCase()).contains(name);
        });

        for (final d in matchingDirs) {
          final dirPath = d['uri'];
          if (await _hasValidRoms(dirPath, system.system.extensions)) {
            if (emuDeckSaves != null) {
              final config = await _getEmuDeckConfig(emuDeckSaves, system.system.id);
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
      developer.log('SCAN: Library scan failed', name: 'VaultSync', level: 900, error: e);
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
      buf.writeln('  ${entry.key.toUpperCase()}: path=${entry.value}, core=${emu ?? "NOT SET"}');
    }
    developer.log(buf.toString().trimRight(), name: 'VaultSync', level: 800);
  }

  Future<bool> mkdirs(String path) async {
    if (!Platform.isAndroid) {
      await Directory(path).create(recursive: true);
      return true;
    }
    try {
      return await _platform.invokeMethod<bool>('mkdirs', {'path': path}) ?? false;
    } catch (e) {
      developer.log('PATH: mkdirs failed for $path', name: 'VaultSync', level: 900, error: e);
      return false;
    }
  }

  Future<String?> getSwitchSavePathForGame(String systemId, String gameId) async => await getEffectivePath(systemId);

  /// Probes the Switch/Eden emulator NAND directory to discover the user's profile ID.
  /// Used for first-restore scenarios where no local save files exist yet to probe from.
  Future<String?> probeProfileId(String effectivePath) async {
    if (!Platform.isAndroid) return null;

    // Use native probing for all Android paths (SAF and Shizuku)
    // because Dart I/O cannot see inside /Android/data.
    try {
      // 1. Try to read the real ID from Eden's profiles.dat first
      final edenId = await _platform.invokeMethod<String?>('readEdenUserId', {'uri': effectivePath});
      if (edenId != null) {
        developer.log('EDEN: Discovered real User ID via profiles.dat: $edenId', name: 'VaultSync', level: 800);
        return edenId;
      }

      // 2. Fallback to general Switch profile discovery
      return await _platform.invokeMethod<String?>('findSwitchProfileId', {'uri': effectivePath});
    } catch (e) {
      developer.log('PROBE: Native profile discovery failed', name: 'VaultSync', level: 900, error: e);
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
  static Future<String> resolveSwitchPackageRootPosix(String path) async {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;

    // If the path already is the files root, leave it alone.
    if (await Directory('$normalized/nand/user/save').exists()) {
      return normalized;
    }
    // If the path is the package dir (one above files root), walk down.
    if (await Directory('$normalized/files/nand/user/save').exists()) {
      return '$normalized/files';
    }
    return normalized;
  }

  /// Picks the active Switch profile ID from a `0000000000000000` directory.
  ///
  /// Mirrors Argosy's `SwitchSaveHandler.findActiveProfileFolder` mtime
  /// fallback: if exactly one non-zero profile exists, it wins; otherwise the
  /// one with the most-recently-touched subtree is picked. Exposed at
  /// library-level for unit testing.
  static Future<String?> pickActiveProfileFromZeroUserDir(
      Directory zeroUserDir) async {
    if (!await zeroUserDir.exists()) return null;

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
    final saves = await getSystemPath('retroarch') ?? await suggestSavePathById('retroarch');
    final states = (saves.endsWith('/saves')) ? '${saves.substring(0, saves.length - 6)}/states' : '$saves/states';
    return {'saves': saves, 'states': states};
  }
}
