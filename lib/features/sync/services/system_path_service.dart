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
      print('⚠️ CONFIG: Failed to load path_config.json: $e');
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
  Future<Map<String, String>> getAllSystemPaths() async {
    if (_cachedPaths != null) return _cachedPaths!;
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('system_path_'));
    final Map<String, String> paths = {};
    for (final key in keys) {
      final systemId = key.replaceFirst('system_path_', '');
      paths[systemId] = prefs.getString(key)!;
    }
    _cachedPaths = paths;
    return paths;
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
        print('🛠️ PATH: Auto-correcting 3DS path to include /saves');
        path = p.join(path, 'saves');
        await setSystemPath(systemId, path);
      }

      // 2. Pull Switch/Eden back to the 'files' root if it's too deep
      if (sid == 'switch' || sid == 'eden') {
        if (path.endsWith('nand/user/save')) {
           print('🛠️ PATH: Auto-migrating Switch POSIX path from /save to /files');
           path = path.substring(0, path.lastIndexOf('/nand/user/save'));
           await setSystemPath(systemId, path);
        } else if (path.contains('nand%2Fuser%2Fsave')) {
           print('🛠️ PATH: Auto-migrating Switch SAF path from /save to /files');
           path = path.split('nand%2Fuser%2Fsave').first;
           if (path.endsWith('%2F')) path = path.substring(0, path.length - 3);
           await setSystemPath(systemId, path);
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
    final path = rawPath.endsWith('/') ? rawPath.substring(0, rawPath.length - 1) : rawPath;
    String? emuDeckSaves;
    if (await Directory('$path/roms').exists() && await Directory('$path/saves').exists()) {
      emuDeckSaves = '$path/saves';
    } else if (path.toLowerCase().endsWith('/roms') && await Directory('${Directory(path).parent.path}/saves').exists()) {
      emuDeckSaves = '${Directory(path).parent.path}/saves';
    }
    if (emuDeckSaves != null) {
      await prefs.setString('emudeck_saves_path', emuDeckSaves);
      print('🛠️ EMUDECK: Detected saves at $emuDeckSaves');
    } else {
      await prefs.remove('emudeck_saves_path');
    }
  }

  Future<String?> getEmuDeckSavesPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('emudeck_saves_path');
  }

  Future<String?> openDirectoryPicker({String? initialUri}) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return await getDirectoryPath(initialDirectory: initialUri, confirmButtonText: 'Select Folder');
    }
    try { return await _platform.invokeMethod('openSafDirectoryPicker', {'initialUri': initialUri}); }
    on PlatformException catch (_) { return null; }
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

  Future<bool> _hasValidRoms(Directory dir, List<String> validExtensions) async {
    if (validExtensions.isEmpty) return false;
    final extSet = validExtensions.map((e) => e.toLowerCase()).toSet();
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase();
          if (fileName.startsWith('.')) continue;
          final ext = fileName.contains('.') ? fileName.split('.').last : '';
          if (ext.isNotEmpty && extSet.contains(ext)) {
            print("🎮 SCAN: Found valid ROM: $fileName");
            return true;
          }
        }
      }
    } catch (e) {
      print('⚠️ SCAN: Error checking ROMs in ${dir.path}: $e');
    }
    return false;
  }

  Future<Map<String, String>> _getEmuDeckConfig(String emuDeckSaves, String systemId) async {
    await _ensureConfigLoaded();
    final base = emuDeckSaves;
    final sid = systemId.toLowerCase();
    
    String findFolder(String parent, String target) {
      try {
        final dir = Directory(parent);
        if (!dir.existsSync()) return "$parent/$target";
        
        // True case-insensitive lookup: list entities and compare names
        for (final entity in dir.listSync()) {
          final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.toLowerCase() == target.toLowerCase()) return entity.path;
        }
      } catch (e) {
        print('⚠️ EMUDECK: Error finding folder $target in $parent: $e');
      }
      // Fallback: return fabricated path if not found, preserving the requested casing
      return "$parent/$target";
    }

    String wikiPath(String emulator, {String sub = "saves"}) {
       final root = findFolder(base, emulator);
       if (sub.isEmpty) return root;
       return "$root/$sub";
    }

    final Map? emuMap = _config?['emuMap'];
    final config = emuMap?[sid];

    if (config != null) {
      final emulator = config['emulator'];
      final sub = config['sub'] ?? "saves";
      
      if (sid == "switch" || sid == "eden") {
        // EmuDeck Switch saves are usually at saves/yuzu/ (no extra 'saves' subfolder)
        final yuzuRoot = wikiPath("yuzu", sub: "");
        if (Directory(yuzuRoot).existsSync()) return { "path": yuzuRoot, "emulatorId": "switch.yuzu.desktop" };
        return { "path": wikiPath("ryujinx", sub: ""), "emulatorId": "switch.ryujinx.desktop" };
      }
      
      final mainPath = wikiPath(emulator, sub: sub);
      if (Directory(mainPath).existsSync() || (config['retroArchId'] ?? "").isEmpty) {
        return { "path": mainPath, "emulatorId": config['desktopId'] };
      }
      return { "path": wikiPath("retroarch"), "emulatorId": config['retroArchId'] };
    }

    final Map? retroArchCores = _config?['retroArchCores'];
    return { 'path': wikiPath('retroarch'), 'emulatorId': retroArchCores?[sid] ?? '' };
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
          print('🛠️ PATH: Migrating legacy standalone path for RA core $emulatorId');
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
          print('🛠️ PATH: Using SAF effective path for $systemId: $rawPath');
          return rawPath;
       }
       final persistedUri = prefs.getString("saf_uri_$posixPath");
       if (persistedUri != null) {
          print('🛠️ PATH: Using persisted SAF URI for $systemId: $persistedUri');
          return persistedUri;
       }
       print('🛠️ PATH: Falling back to POSIX for $systemId: $posixPath');
       return rawPath; 
    }
    
    print('🛠️ PATH: Using POSIX effective path for $systemId: $posixPath');
    return posixPath;
  }

  /// Automatically scans a ROM library to detect systems and their save locations.
  Future<List<Map<String, String>>> scanLibrary(String inputPath) async {
    final results = <Map<String, String>>[];
    try {
      String rawPath = _convertToPosix(inputPath);
      final path = rawPath.endsWith('/') ? rawPath.substring(0, rawPath.length - 1) : rawPath;
      final dir = Directory(path);
      print('🔍 SCAN: Starting Library Scan for path: "$path"');
      if (!await dir.exists()) return [];
      Directory romsDir = dir;
      Directory? emuDeckSaves;
      if (await Directory('$path/roms').exists() && await Directory('$path/saves').exists()) {
        romsDir = Directory('$path/roms');
        emuDeckSaves = Directory('$path/saves');
      } else if (path.toLowerCase().endsWith('/roms') && await Directory("${Directory(path).parent.path}/saves").exists()) {
        emuDeckSaves = Directory("${Directory(path).parent.path}/saves");
      }
      final systems = await _emulatorRepository.loadSystems();
      final List<FileSystemEntity> list = await romsDir.list().toList();
      
      for (final system in systems) {
        final matchingDirs = list.whereType<Directory>().where((d) {
          final name = d.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull?.toLowerCase() ?? 
                       d.path.split("/").last.toLowerCase();
          
          return name == system.system.id.toLowerCase() || 
                 name == system.system.name.toLowerCase() || 
                 system.system.folders.map((f) => f.toLowerCase()).contains(name);
        });
        for (final d in matchingDirs) {
          if (await _hasValidRoms(d, system.system.extensions)) {
            if (emuDeckSaves != null) {
              final config = await _getEmuDeckConfig(emuDeckSaves.path, system.system.id);
              results.add({
                'systemId': system.system.id, 
                'path': config['path']!, 
                'emulatorId': config['emulatorId']!
              });
            } else {
              // If not EmuDeck, we don't know where the saves are.
              // We report the system is found but don't provide a path,
              // allowing suggestSavePath() to handle it later.
              results.add({'systemId': system.system.id});
            }
          }
        }
      }
    } catch (e) { print('⚠️ SCAN: Library scan failed: $e'); }
    await logConfiguredPaths();
    return results;
  }

  Future<void> logConfiguredPaths() async {
    final paths = await getAllSystemPaths();
    final prefs = await SharedPreferences.getInstance();
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🛠️ VAULTSYNC CONFIGURATION DUMP');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    for (final entry in paths.entries) {
      final emu = prefs.getString("system_emulator_${entry.key}");
      print('👾 ${entry.key.toUpperCase()}:');
      print('   Path: ${entry.value}');
      print('   Core: ${emu ?? "NOT SET"}');
    }
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }

  Future<bool> mkdirs(String path) async {
    if (!Platform.isAndroid) {
      await Directory(path).create(recursive: true);
      return true;
    }
    try {
      return await _platform.invokeMethod<bool>('mkdirs', {'path': path}) ?? false;
    } catch (e) {
      print('⚠️ PATH: mkdirs failed for $path: $e');
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
        print('🎮 EDEN: Discovered real User ID via profiles.dat: $edenId');
        return edenId;
      }

      // 2. Fallback to general Switch profile discovery
      return await _platform.invokeMethod<String?>('findSwitchProfileId', {'uri': effectivePath});
    } catch (e) {
      print('⚠️ PROBE: Native profile discovery failed: $e');
    }

    // Fallback for simple non-restricted POSIX paths (SD card, etc)
    final posixPath = effectivePath.replaceFirst('shizuku://', '');
    String basePath = posixPath;
    if (basePath.contains('nand/user/save')) {
      basePath = basePath.substring(0, basePath.indexOf('nand/user/save'));
    }
    
    final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
    for (final base in ['$basePath/nand/user/save/0000000000000000', '$basePath/files/nand/user/save/0000000000000000']) {
      final saveDir = Directory(base);
      if (!await saveDir.exists()) continue;
      try {
        await for (final entity in saveDir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (profileRegex.hasMatch(name) && name != '00000000000000000000000000000000') return name;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, String>> getRetroArchPaths() async {
    final saves = await getSystemPath('retroarch') ?? await suggestSavePathById('retroarch');
    final states = (saves.endsWith('/saves')) ? '${saves.substring(0, saves.length - 6)}/states' : '$saves/states';
    return {'saves': saves, 'states': states};
  }
}
