import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  Future<Map<String, String>> getAllSystemPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('system_path_'));
    final Map<String, String> paths = {};
    for (final key in keys) {
      final systemId = key.replaceFirst('system_path_', '');
      String val = prefs.getString(key)!;
      if (val.startsWith('content://')) {
        final posix = _convertToPosix(val);
        if (!_isProtectedPath(posix)) {
          val = posix;
          await prefs.setString(key, val);
        }
      }
      paths[systemId] = val;
    }
    return paths;
  }

  Future<String?> getSystemPath(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_path_$systemId');
  }

  Future<void> _incrementStorageVersion() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getInt('storage_version') ?? 0;
    await prefs.setInt('storage_version', current + 1);
  }

  Future<int> getStorageVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('storage_version') ?? 0;
  }

  Future<void> setSystemPath(String systemId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('system_path_$systemId', path);
    await _incrementStorageVersion();
  }

  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_emulator_$systemId');
  }

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

  Future<String?> getLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    String? path = prefs.getString('rom_library_path');
    if (path != null && path.startsWith('content://')) {
       final posix = _convertToPosix(path);
       if (!_isProtectedPath(posix)) {
          path = posix;
          await prefs.setString('rom_library_path', path);
       }
    }
    return path;
  }

  Future<void> setLibraryPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rom_library_path', path);
  }

  Future<String?> openDirectoryPicker({String? initialUri}) async {
    try { return await _platform.invokeMethod('openSafDirectoryPicker', {'initialUri': initialUri}); }
    on PlatformException catch (_) { return null; }
  }

  Future<int> _getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;
    try { return await _platform.invokeMethod<int>('getAndroidVersion') ?? 0; }
    catch (_) { return 0; }
  }

  Future<bool> ensureSafPermission(String path) async {
    if (!Platform.isAndroid) return true;
    
    // 1. Shizuku Explicit Check
    if (path.startsWith('shizuku://')) {
       final shizuku = await _platform.invokeMethod<Map>('checkShizukuStatus');
       if (shizuku == null || shizuku['running'] == false) {
          throw Exception('Shizuku is not running. Please start it to access restricted folders.');
       }
       if (shizuku['authorized'] == false) {
          throw Exception('Shizuku permission denied. Please authorize VaultSync in the Shizuku app.');
       }
       return true;
    }

    final androidVersion = await _getAndroidVersion();
    if (androidVersion <= 33) return true;
    if (!_isProtectedPath(path)) return true;
    
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('use_shizuku') ?? false) {
       throw Exception('Shizuku Bridge is enabled in Settings, but the path is not using it. Try re-scanning.');
    }

    // 2. SAF Persisted Permission Check
    final persistedUri = prefs.getString('saf_uri_$path');
    if (persistedUri != null) {
      final hasPermission = await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
      if (hasPermission == true) return true;
    }
    
    // 3. Request New SAF Permission
    final pickedUri = await openDirectoryPicker();
    if (pickedUri != null) { await prefs.setString('saf_uri_$path', pickedUri); return true; }
    
    throw Exception('SAF Permission denied for restricted folder: $path');
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
    final nandRel = 'nand/user/save/0000000000000000/';
    final fullNandPath = '$base$nandRel';
    try {
      final listJson = await _platform.invokeMethod<String>('listSafDirectory', {'uri': fullNandPath});
      if (listJson != null) {
         final List list = jsonDecode(listJson);
         final folders = list.where((i) => i['isDirectory'] == true).toList();
         if (folders.isNotEmpty) return folders.first['uri'] as String;
      }
    } catch (e) { print('⚠️ DIVE: Native probe failed for $fullNandPath: $e'); }
    return '${base}nand/user/save/0000000000000000/0000000000000001';
  }

  Future<String> getEffectivePath(String systemId) async {
    final rawPath = await getSystemPath(systemId);
    if (rawPath == null) return suggestSavePathById(systemId);
    final androidVersion = await _getAndroidVersion();
    
    String path = rawPath;
    if (androidVersion <= 33 || !_isProtectedPath(path)) {
      path = _convertToPosix(rawPath);
    } else {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('use_shizuku') ?? false) { if (!path.startsWith('shizuku://')) path = 'shizuku://$path'; }
      else {
        final persistedUri = prefs.getString('saf_uri_$path');
        if (persistedUri != null && await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri}) == true) path = persistedUri;
      }
    }
    if (systemId.toLowerCase() == 'switch' || systemId.toLowerCase() == 'eden') {
       final clean = _convertToPosix(path);
       if (clean.endsWith('/files') || clean.endsWith('/files/')) return await _diveIntoSwitchSaves(path);
    }
    return path;
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

  Future<String?> getSwitchSavePathForGame(String systemId, String gameId) async => await getEffectivePath(systemId);
  Future<Map<String, String>> getRetroArchPaths() async {
    return {'saves': '/storage/emulated/0/RetroArch/saves', 'states': '/storage/emulated/0/RetroArch/states'};
  }
}
