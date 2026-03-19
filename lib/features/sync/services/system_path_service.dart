import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
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

class SystemPathService {
  final EmulatorRepository _emulatorRepository;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  Map<String, String>? _cachedPaths;

  SystemPathService(this._emulatorRepository);

  EmulatorRepository getEmulatorRepository() => _emulatorRepository;

  static const Map<String, String> standaloneDefaults = {
    'ps2': '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
    'aethersx2': '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
    'nethersx2': '/storage/emulated/0/Android/data/xyz.nethersx2.android/files/memcards',
    'pcsx2': '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
    'ppsspp': '/storage/emulated/0/PSP/SAVEDATA',
    'duckstation': '/storage/emulated/0/Android/data/com.github.stenzek.duckstation/files/memcards',
    'duckstation_legacy': '/storage/emulated/0/DuckStation/memcards',
    'dolphin': '/storage/emulated/0/Android/data/org.dolphinemu.dolphinemu/files',
    'wii': '/storage/emulated/0/Android/data/org.dolphinemu.dolphinemu/files',
    'gc': '/storage/emulated/0/Android/data/org.dolphinemu.dolphinemu/files',
    'citra': '/storage/emulated/0/Citra',
    'yuzu': '/storage/emulated/0/Android/data/org.yuzu.yuzu_emu/files',
    'eden': '/storage/emulated/0/Android/data/dev.eden.eden_emulator/files',
    'eden_legacy': '/storage/emulated/0/Android/data/dev.legacy.eden_emulator/files',
    'eden_optimized': '/storage/emulated/0/Android/data/com.miHoYo.Yuanshen/files',
    'eden_nightly': '/storage/emulated/0/Android/data/dev.eden.eden_nightly/files',
    '3ds.azahar': '/storage/emulated/0/Azahar',
    'redream': '/storage/emulated/0/Android/data/io.recompiled.redream/files/saves',
    'flycast': '/storage/emulated/0/flycast/data',
    'melonds': '/storage/emulated/0/Android/data/me.magnum.melonds/files/saves',
  };

  String _getDesktopHome() {
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
    return Platform.environment['HOME'] ?? '/home';
  }

  String? _getDesktopDefault(String key, String systemId) {
    final home = _getDesktopHome();
    final Map<String, Map<String, String>> desktopPaths = {
      'windows': {
        'ps2': '$home\\Documents\\PCSX2\\memcards',
        'ppsspp': '$home\\Documents\\PPSSPP\\SAVEDATA',
        'dolphin': '$home\\Documents\\Dolphin Emulator',
        'citra': '$home\\AppData\\Roaming\\Citra\\sdmc\\Nintendo 3DS',
        'yuzu': '$home\\AppData\\Roaming\\yuzu\\nand',
        'retroarch': '$home\\AppData\\Roaming\\RetroArch\\saves',
      },
      'linux': {
        'ps2': '$home/.config/PCSX2/memcards',
        'ppsspp': '$home/.config/ppsspp/PSP/SAVEDATA',
        'dolphin': '$home/.local/share/dolphin-emu',
        'citra': '$home/.local/share/citra-emu/sdmc/Nintendo 3DS',
        'yuzu': '$home/.local/share/yuzu/nand',
        'retroarch': '$home/.config/retroarch/saves',
      }
    };
    final platform = Platform.isWindows ? 'windows' : 'linux';
    String? path = desktopPaths[platform]?[key];
    if (path != null && key == 'dolphin') {
      if (systemId == 'gc') path = '$path/GC';
      if (systemId == 'wii') path = '$path/Wii';
    }
    return path;
  }

  /// Returns all configured system IDs and their corresponding local base paths.
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

  /// Returns the base path configured for a specific system ID.
  Future<String?> getSystemPath(String systemId) async {
    final paths = await getAllSystemPaths();
    return paths[systemId];
  }

  Future<void> _incrementStorageVersion() async {
    _cachedPaths = null;
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt('storage_version') ?? 0;
    await prefs.setInt('storage_version', current + 1);
  }

  /// Returns the current storage version, used to trigger UI refreshes when paths change.
  Future<int> getStorageVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('storage_version') ?? 0;
  }

  /// Saves the base path for a specific system ID.
  Future<void> setSystemPath(String systemId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('system_path_$systemId', path);
    await _incrementStorageVersion();
  }

  /// Returns the preferred emulator ID for a specific system.
  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_emulator_$systemId');
  }

  /// Saves the preferred emulator ID for a specific system.
  Future<void> setSystemEmulator(String systemId, String emulatorId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('system_emulator_$systemId', emulatorId);
    await _incrementStorageVersion();
  }

  String suggestSavePath(EmulatorInfo emulator, String systemId) {
    if (Platform.isWindows || Platform.isLinux) {
      for (final entry in standaloneDefaults.entries) {
        if (emulator.uniqueId.contains(entry.key)) {
          final desktopPath = _getDesktopDefault(entry.key, systemId);
          if (desktopPath != null) return desktopPath;
        }
      }
      return '${_getDesktopHome()}/RetroArch/saves';
    }
    for (final entry in standaloneDefaults.entries) {
      if (emulator.uniqueId.contains(entry.key)) {
        String path = entry.value;
        if (entry.key == 'dolphin') {
          if (systemId == 'gc') path = '$path/GC';
          if (systemId == 'wii') path = '$path/Wii';
        }
        return path;
      }
    }
    return '/storage/emulated/0/RetroArch/saves';
  }

  /// Returns a suggested save path for a system ID based on platform defaults.
  String suggestSavePathById(String systemId) {
    final lowerId = systemId.toLowerCase();
    if (Platform.isWindows || Platform.isLinux) {
      for (final entry in standaloneDefaults.entries) {
        if (lowerId.contains(entry.key) || entry.key.contains(lowerId)) {
          final desktopPath = _getDesktopDefault(entry.key, systemId);
          if (desktopPath != null) return desktopPath;
        }
      }
      return '${_getDesktopHome()}/RetroArch/saves';
    }
    return standaloneDefaults[lowerId] ?? '/storage/emulated/0/RetroArch/saves';
  }

  /// Returns the configured library folder path.
  Future<String?> getLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('rom_library_path');
  }

  /// Saves the library folder path.
  Future<void> setLibraryPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rom_library_path', path);
  }

  /// Opens the native directory picker (SAF on Android, platform picker on Desktop) 
  /// and returns the picked URI or absolute path.
  Future<String?> openDirectoryPicker({String? initialUri}) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return await getDirectoryPath(
        initialDirectory: initialUri,
        confirmButtonText: 'Select Folder',
      );
    }
    try { return await _platform.invokeMethod('openSafDirectoryPicker', {'initialUri': initialUri}); }
    on PlatformException catch (_) { return null; }
  }

  Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;
    try { return await _platform.invokeMethod<int>('getAndroidVersion') ?? 0; }
    catch (_) { return 0; }
  }

  /// Ensures that the app has persistent SAF permissions for the given restricted path.
  /// Handles Shizuku fallback for Android 14+ if configured.
  Future<bool> ensureSafPermission(String path) async {
    if (!Platform.isAndroid) return true;
    
    // 1. Shizuku Explicit Check
    if (path.startsWith('shizuku://')) {
       final shizuku = await _platform.invokeMethod<Map>('checkShizukuStatus');
       if (shizuku == null || shizuku['running'] == false) throw Exception('Shizuku not running');
       if (shizuku['authorized'] == false) throw Exception('Shizuku not authorized');
       return true;
    }

    if (!_isProtectedPath(path)) return true;
    
    final prefs = await SharedPreferences.getInstance();
    final androidVersion = await _getAndroidVersion();
    
    // On Android 14+, prefer Shizuku if enabled
    if (androidVersion >= 34 && (prefs.getBool('use_shizuku') ?? false)) return true;

    // 2. SAF Persisted Permission Check
    final persistedUri = prefs.getString('saf_uri_$path');
    if (persistedUri != null) {
      final hasPermission = await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
      if (hasPermission == true) return true;
    }
    
    // 3. Request New SAF Permission
    final pickedUri = await openDirectoryPicker(initialUri: _buildInitialUri(path));
    if (pickedUri != null) { await prefs.setString('saf_uri_$path', pickedUri); return true; }
    
    throw Exception('SAF Permission required for restricted folder: $path');
  }

  String? _buildInitialUri(String path) {
    if (path.startsWith('content://')) return path;
    if (path.startsWith('/storage/emulated/0/')) {
      final relPath = path.replaceFirst('/storage/emulated/0/', '');
      final encoded = Uri.encodeComponent(relPath);
      return 'content://com.android.externalstorage.documents/document/primary%3A$encoded';
    }
    return null;
  }

  bool _isProtectedPath(String path) {
     final lower = path.toLowerCase();
     return lower.contains('android/data') || lower.contains('android/obb');
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

  Future<String> _diveIntoSwitchSaves(String root) async {
    final base = root.endsWith('/') ? root : '$root/';
    
    // Switch Standard: Path to saves is highly standardized.
    // Even if picked at root, we walk down to the 0000...0001 folder.
    final pathSegments = [
      'nand', 'user', 'save', '0000000000000000', '0000000000000001'
    ];

    String currentUri = root;
    
    // Attempt to walk down the segments
    for (final segment in pathSegments) {
       try {
         final listJson = await _platform.invokeMethod<String>('listSafDirectory', {'uri': currentUri});
         if (listJson != null) {
            final List list = jsonDecode(listJson);
            final match = list.where((i) => i['name'].toString().toLowerCase() == segment.toLowerCase()).firstOrNull;
            if (match != null) {
               currentUri = match['uri'];
               continue;
            }
         }
       } catch (e) { break; }
       
       // If we reach here, a segment was missing or listing failed.
       // Try common 'files/' nested variant
       if (segment == 'nand' && !currentUri.contains('/nand')) {
          try {
             final listJson = await _platform.invokeMethod<String>('listSafDirectory', {'uri': currentUri});
             final List list = jsonDecode(listJson ?? '[]');
             final filesMatch = list.where((i) => i['name'].toString().toLowerCase() == 'files').firstOrNull;
             if (filesMatch != null) {
                currentUri = filesMatch['uri'];
                // Restart search from currentUri with same segment
                final subListJson = await _platform.invokeMethod<String>('listSafDirectory', {'uri': currentUri});
                final subList = jsonDecode(subListJson ?? '[]');
                final subMatch = subList.where((i) => i['name'].toString().toLowerCase() == segment.toLowerCase()).firstOrNull;
                if (subMatch != null) { currentUri = subMatch['uri']; continue; }
             }
          } catch (_) {}
       }
       break;
    }

    return currentUri;
  }

  /// Resolves the effective local save path for a system, handling 
  /// Shizuku, SAF content URIs, and standard local filesystem variants.
  Future<String> getEffectivePath(String systemId) async {
    final rawPath = await getSystemPath(systemId);
    if (rawPath == null) return suggestSavePathById(systemId);
    if (!Platform.isAndroid) return rawPath;

    final androidVersion = await _getAndroidVersion();
    final prefs = await SharedPreferences.getInstance();
    final useShizuku = prefs.getBool('use_shizuku') ?? false;

    // 1. Shizuku Path (Android 14+ ONLY)
    if (useShizuku && androidVersion >= 34 && _isProtectedPath(rawPath)) {
       return 'shizuku://$rawPath';
    }

    // 2. SAF Path (Android 11-13 for restricted folders)
    if (_isProtectedPath(rawPath)) {
       final persistedUri = prefs.getString('saf_uri_$rawPath');
       if (persistedUri != null) {
          return persistedUri;
       }
    }

    // 3. POSIX Fallback (Standard folders or Legacy SDK)
    return _convertToPosix(rawPath);
  }

  Future<bool> _hasValidFiles(Directory dir) async {
    try {
      final List<FileSystemEntity> list = await dir.list().toList();
      if (list.isEmpty) return false;
      return list.where((e) {
        if (e is! File) return true;
        final name = e.path.split('/').last.toLowerCase();
        return !name.endsWith('.txt') && !name.startsWith('.');
      }).isNotEmpty;
    } catch (_) { return false; }
  }

  /// Scans a library folder recursively to detect supported emulation systems 
  /// by matching directory names against known system IDs and verifying file content.
  Future<List<Map<String, String>>> scanLibrary(String inputPath) async {
    final results = <Map<String, String>>[];
    try {
      String path = _convertToPosix(inputPath);
      final dir = Directory(path);
      if (!await dir.exists()) return [];
      final systems = await _emulatorRepository.loadSystems();
      final List<FileSystemEntity> list = await dir.list().toList();
      for (final system in systems) {
        final matchingDirs = list.whereType<Directory>().where((d) {
          final name = d.path.split('/').last.toLowerCase();
          return name == system.system.id.toLowerCase() || name == system.system.name.toLowerCase();
        });
        for (final d in matchingDirs) {
          if (await _hasValidFiles(d)) {
            results.add({'systemId': system.system.id, 'path': d.path});
          }
        }
      }
    } catch (e) { print('⚠️ SCAN: Library scan failed: $e'); }
    return results;
  }

  /// Resolves the effective local path for Switch game-specific saves.
  Future<String?> getSwitchSavePathForGame(String systemId, String gameId) async => await getEffectivePath(systemId);
  
  /// Resolves standard RetroArch paths for saves and states.
  Future<Map<String, String>> getRetroArchPaths() async {
    final saves = await getSystemPath('retroarch') ?? suggestSavePathById('retroarch');
    final states = saves.endsWith('/saves') 
        ? '${saves.substring(0, saves.length - 6)}/states' 
        : '$saves/states'; // Fallback if the configured path doesn't end in /saves

    return {
      'saves': saves,
      'states': states
    };
  }}
