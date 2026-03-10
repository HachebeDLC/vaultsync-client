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
  // Watch for changes in storage version to force reload
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
    'nethersx2': '/storage/emulated/0/Android/data/xyz.aethersx2.android/files/memcards',
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

  String _getDesktopConfigDir() {
    if (Platform.isWindows) return Platform.environment['APPDATA'] ?? 'C:\\Users\\Default\\AppData\\Roaming';
    return '${_getDesktopHome()}/.config';
  }

  String? _getEmuDeckRoot() {
    if (!Platform.isLinux) return null;
    final home = _getDesktopHome();
    
    // 1. Check Home directory
    final homeEmu = Directory('$home/Emulation');
    if (homeEmu.existsSync()) return homeEmu.path;
    
    // 2. Check SD Card (Steam Deck standard)
    final runMedia = Directory('/run/media');
    if (runMedia.existsSync()) {
      try {
        final users = runMedia.listSync();
        for (final user in users) {
          if (user is Directory) {
            final drives = user.listSync();
            for (final drive in drives) {
              if (drive is Directory) {
                final emuPath = Directory('${drive.path}/Emulation');
                if (emuPath.existsSync()) return emuPath.path;
              }
            }
          }
        }
      } catch (_) {}
    }
    
    return null;
  }

  String? _getWindowsEmuRoot() {
    if (!Platform.isWindows) return null;
    final emuPath = Directory('C:\\Emulation');
    if (emuPath.existsSync()) return emuPath.path;
    return null;
  }

  String? _getDesktopDefault(String key, String systemId) {
    final home = _getDesktopHome();
    final config = _getDesktopConfigDir();
    final emuDeckRoot = _getEmuDeckRoot();
    final winEmuRoot = _getWindowsEmuRoot();
    
    // Prioritize Linux EmuDeck if found
    if (emuDeckRoot != null) {
      final emuPath = '$emuDeckRoot/saves/$key/saves';
      if (Directory(emuPath).existsSync()) return emuPath;
      final emuPathAlt = '$emuDeckRoot/saves/$key';
      if (Directory(emuPathAlt).existsSync()) return emuPathAlt;
    }

    // Prioritize Windows C:\Emulation if found
    if (winEmuRoot != null) {
      final emuPath = '$winEmuRoot\\saves\\$key\\saves';
      if (Directory(emuPath).existsSync()) return emuPath;
      final emuPathAlt = '$winEmuRoot\\saves\\$key';
      if (Directory(emuPathAlt).existsSync()) return emuPathAlt;
    }

    final Map<String, Map<String, String>> desktopPaths = {
      'windows': {
        'ps2': '$home\\Documents\\PCSX2\\memcards',
        'aethersx2': '$home\\Documents\\PCSX2\\memcards',
        'pcsx2': '$home\\Documents\\PCSX2\\memcards',
        'duckstation': '$home\\Documents\\DuckStation\\memcards',
        'ppsspp': '$home\\Documents\\PPSSPP\\SAVEDATA',
        'dolphin': '$home\\Documents\\Dolphin Emulator',
        'citra': '$config\\Citra\\sdmc\\Nintendo 3DS',
        'yuzu': '$config\\yuzu\\nand',
        'retroarch': '$config\\RetroArch\\saves',
      },
      'linux': {
        'ps2': '$home/.config/PCSX2/memcards',
        'pcsx2': '$home/.config/PCSX2/memcards',
        'duckstation': '$home/.config/duckstation/memcards',
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

  Future<Map<String, String>> getRetroArchPaths() async {
    final List<String> configPaths = [];
    
    if (Platform.isAndroid) {
      configPaths.addAll([
        '/storage/emulated/0/Android/data/com.retroarch/files/retroarch.cfg',
        '/storage/emulated/0/Android/data/com.retroarch.aarch64/files/retroarch.cfg',
        '/storage/emulated/0/Android/data/com.retroarch.ra32/files/retroarch.cfg',
        '/storage/emulated/0/RetroArch/retroarch.cfg',
      ]);
    } else if (Platform.isWindows) {
      final winEmu = _getWindowsEmuRoot();
      if (winEmu != null) {
        configPaths.add('$winEmu\\retroarch\\retroarch.cfg');
      }
      configPaths.add('${_getDesktopConfigDir()}\\RetroArch\\retroarch.cfg');
    } else if (Platform.isLinux) {
      final emuDeck = _getEmuDeckRoot();
      if (emuDeck != null) {
        configPaths.add('$emuDeck/retroarch/retroarch.cfg');
      }
      configPaths.add('${_getDesktopHome()}/.config/retroarch/retroarch.cfg');
    }

    for (final path in configPaths) {
      final file = File(path);
      if (await file.exists()) {
        try {
          final lines = await file.readAsLines();
          String? saves;
          String? states;
          for (final line in lines) {
            if (line.startsWith('savefile_directory')) {
              saves = line.split('=').last.replaceAll('"', '').trim();
            } else if (line.startsWith('savestate_directory')) states = line.split('=').last.replaceAll('"', '').trim();
          }
          if (saves != null || states != null) {
             final defaultSaves = Platform.isAndroid ? '/storage/emulated/0/RetroArch/saves' : '${_getDesktopHome()}/RetroArch/saves';
             final defaultStates = Platform.isAndroid ? '/storage/emulated/0/RetroArch/states' : '${_getDesktopHome()}/RetroArch/states';
             return {'saves': saves ?? defaultSaves, 'states': states ?? defaultStates};
          }
        } catch (_) {}
      }
    }
    
    final defaultSaves = Platform.isAndroid ? '/storage/emulated/0/RetroArch/saves' : '${_getDesktopHome()}/RetroArch/saves';
    final defaultStates = Platform.isAndroid ? '/storage/emulated/0/RetroArch/states' : '${_getDesktopHome()}/RetroArch/states';
    return {'saves': defaultSaves, 'states': defaultStates};
  }

  Future<String?> getLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('rom_library_path');
  }

  Future<void> setLibraryPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rom_library_path', path);
  }

  Future<String?> getSystemPath(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_path_$systemId');
  }

  Future<void> clearAllSystems() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('system_path_') || k.startsWith('system_emulator_'));
    for (final key in keys) {
      await prefs.remove(key);
    }
    await _incrementStorageVersion();
    print('🧹 STORAGE: Cleared all system configurations');
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
    print('💾 STORAGE: Saved path for $systemId -> $path');
  }

  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('system_emulator_$systemId');
  }

  Future<void> setSystemEmulator(String systemId, String emulatorId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('system_emulator_$systemId', emulatorId);
    await _incrementStorageVersion();
    print('💾 STORAGE: Saved emulator for $systemId -> $emulatorId');
  }

  String suggestSavePath(EmulatorInfo emulator, String systemId) {
    if (Platform.isWindows || Platform.isLinux) {
      // Try to find a desktop default for this emulator
      for (final entry in standaloneDefaults.entries) {
        if (emulator.uniqueId.contains(entry.key)) {
          final desktopPath = _getDesktopDefault(entry.key, systemId);
          if (desktopPath != null) return desktopPath;
        }
      }
      return _getDesktopDefault('retroarch', systemId) ?? '${_getDesktopHome()}/RetroArch/saves';
    }

    // 1. First, check if this specific emulator matches one of our standalone defaults
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

    // 2. If no match, check if it's RetroArch
    if (emulator.uniqueId.contains('.ra.') || emulator.uniqueId.contains('retroarch')) {
      return '/storage/emulated/0/RetroArch/saves';
    }

    return '/storage/emulated/0/RetroArch/saves';
  }

  String suggestSavePathById(String systemId) {
    final lowerId = systemId.toLowerCase();
    
    if (Platform.isWindows || Platform.isLinux) {
      // Try to find a desktop default for this emulator
      for (final entry in standaloneDefaults.entries) {
        if (lowerId.contains(entry.key) || entry.key.contains(lowerId)) {
          final desktopPath = _getDesktopDefault(entry.key, systemId);
          if (desktopPath != null) return desktopPath;
        }
      }
      return _getDesktopDefault('retroarch', systemId) ?? '${_getDesktopHome()}/RetroArch/saves';
    }

    // First, try matching based on our standalone defaults mapping
    for (final entry in standaloneDefaults.entries) {
      if (lowerId.contains(entry.key)) {
        String path = entry.value;
        if (entry.key == 'dolphin') {
          if (lowerId == 'gc') path = '$path/GC';
          if (lowerId == 'wii') path = '$path/Wii';
        }
        return path;
      }
    }

    // Default fallback to RetroArch
    return '/storage/emulated/0/RetroArch/saves';
  }

  Future<String?> getSwitchSavePathForGame(String systemId, String gameId) async {
    final basePath = await getSystemPath(systemId);
    if (basePath == null) return null;

    // Eden/Yuzu structure: <base>/nand/user/save/0000000000000000/<USER_ID>/<TITLE_ID>/
    final saveRoot = '$basePath/nand/user/save/0000000000000000';
    
    try {
      final rootDir = Directory(saveRoot);
      if (await rootDir.exists()) {
        final List<FileSystemEntity> userFolders = await rootDir.list().toList();
        for (final userFolder in userFolders) {
          if (userFolder is Directory) {
            final gamePath = '${userFolder.path}/$gameId';
            if (await Directory(gamePath).exists()) {
              return gamePath;
            }
          }
        }
      }
    } catch (e) {
      print('⚠️ STORAGE: Error scanning Switch save path: $e');
    }

    // Fallback to the old fixed path if scanning fails or nothing is found
    return '$saveRoot/$gameId';
  }

  Future<Map<String, String>> getAllSystemPaths() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // Force sync with disk on Android
    final keys = prefs.getKeys().where((k) => k.startsWith('system_path_'));
    final paths = <String, String>{};
    for (final key in keys) {
      final systemId = key.replaceFirst('system_path_', '');
      final path = prefs.getString(key);
      if (path != null) paths[systemId] = path;
    }
    print('📂 STORAGE: Reloaded and found ${paths.length} configured systems');
    return paths;
  }

  Future<bool> ensureSafPermission(String path) async {
    if (!Platform.isAndroid) return true;
    if (path.startsWith('shizuku://')) return true;
    
    // If it's not a restricted path, no SAF needed for targetSDK 29
    if (!path.contains('/Android/data/')) return true;
    
    // Check if we already have a content:// URI for this path or if we have permission
    final prefs = await SharedPreferences.getInstance();
    final persistedUri = prefs.getString('saf_uri_$path');
    
    if (persistedUri != null) {
      final hasPermission = await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
      if (hasPermission == true) return true;
    }

    // Generate initial URI hint for the picker
    String? initialUri;
    if (path.startsWith('/storage/emulated/0/')) {
      String relPath = path.substring(20).replaceAll('/', '%2F');
      
      // SAF navigation to subfolders in Android/data is often restricted.
      // We target the package root in Android/data, which is the deepest reliable hint.
      if (path.contains('/Android/data/')) {
        final parts = path.split('/Android/data/');
        if (parts.length > 1) {
          final packageName = parts[1].split('/').first;
          relPath = 'Android%2Fdata%2F$packageName';
        } else {
          relPath = 'Android';
        }
      }
      
      // Use the 'tree' format for better reliability
      initialUri = 'content://com.android.externalstorage.documents/tree/primary%3A$relPath';
    }

    // Trigger the picker for the restricted path
    print('🔐 PERMISSION: Requesting SAF access for $path (Hint: $initialUri)');
    final pickedUri = await openDirectoryPicker(initialUri: initialUri);
    
    if (pickedUri != null) {
      await prefs.setString('saf_uri_$path', pickedUri);
      return true;
    }
    
    return false;
  }

  Future<String> getEffectivePath(String systemId) async {
    final path = await getSystemPath(systemId);
    if (path == null) return suggestSavePathById(systemId);
    
    if (path.startsWith('content://') || path.startsWith('shizuku://')) return path;

    if (!Platform.isAndroid) return path;

    final prefs = await SharedPreferences.getInstance();
    
    // Check if Shizuku is preferred for this path
    final useShizuku = prefs.getBool('use_shizuku') ?? false;
    if (useShizuku && path.contains('/Android/data/')) {
      return 'shizuku://$path';
    }

    final persistedUri = prefs.getString('saf_uri_$path');
    
    if (persistedUri != null) {
      final hasPermission = await _platform.invokeMethod<bool>('checkSafPermission', {'uri': persistedUri});
      if (hasPermission == true) {
        // We have permission for a parent folder (e.g. the package root).
        // Build a specific sub-document URI for the intended path.
        if (path.startsWith('/storage/emulated/0/')) {
           final relPath = path.substring(20).replaceAll('/', '%2F');
           // Combine the tree root with the specific document path
           return '$persistedUri/document/primary%3A$relPath';
        }
        return persistedUri;
      }
    }
    
    return path;
  }

  Future<String?> openDirectoryPicker({String? initialUri}) async {
    if (Platform.isWindows || Platform.isLinux) {
      print('📂 PICKER: Requesting desktop directory picker');
      return await FilePicker.platform.getDirectoryPath();
    }

    print('📂 PICKER: Requesting SAF with initialUri hint: $initialUri');
    try { 
      // Ensure the hint URI is properly encoded for the native side
      final result = await _platform.invokeMethod('openSafDirectoryPicker', {
        'initialUri': initialUri,
      }); 
      print('📂 PICKER: Result: $result');
      return result;
    } catch (e) { 
      print('❌ PICKER: Error: $e');
      return null; 
    }
  }

  Future<List<String>> scanLibrary(String rootPath) async {
    print('🔍 SCAN: Initiating Library-First scan on $rootPath');
    final systems = await _emulatorRepository.loadSystems();
    final raPaths = await getRetroArchPaths();
    final foundSystemIds = <String>[];
    
    List<Map<String, dynamic>> rootFolders = [];
    if (rootPath.startsWith('content://')) {
       try {
         final String resultStr = await _platform.invokeMethod('listSafDirectory', {'uri': rootPath});
         final List<dynamic> result = json.decode(resultStr);
         rootFolders = result.map((e) => Map<String, dynamic>.from(e)).where((f) => f['isDirectory'] == true).toList();
       } catch (e) { print('❌ SCAN: SAF failed: $e'); }
    } else {
       final dir = Directory(rootPath);
       if (await dir.exists()) {
          rootFolders = dir.listSync().whereType<Directory>().map((d) => {'name': d.path.split('/').last, 'uri': d.path}).toList();
       }
    }

    final Set<String> matchedFolderUris = {};
    print('📂 SCAN: Found ${rootFolders.length} folders in library. Matching against systems...');

    for (final folder in rootFolders) {
      final folderName = folder['name'].toString().toLowerCase();
      final folderUri = folder['uri'].toString();
      
      if (matchedFolderUris.contains(folderUri)) continue;

      // SKIP: If the folder name is too generic, it must match EXACTLY to a system folders list
      final genericFolders = {'roms', 'saves', 'states', 'data', 'games', 'game', 'media', 'files', 'configs', 'content'};
      bool isGeneric = genericFolders.contains(folderName);

      for (final systemConfig in systems) {
        final system = systemConfig.system;
        if (foundSystemIds.contains(system.id)) continue;

        // MATCH CRITERIA:
        // 1. If it's a specific system folder (e.g. "ps2", "snes") -> MATCH
        // 2. If it's a generic folder -> ONLY MATCH if system ID matches folder name exactly
        bool isPerfectMatch = folderName == system.id.toLowerCase() || 
                              folderName == system.name.toLowerCase().replaceAll(' ', '');
        
        bool isAliasMatch = !isGeneric && system.folders.any((f) => f.toLowerCase() == folderName);

        if (isPerfectMatch || isAliasMatch) {
          // HARDENING: Only validate against "heavy" extensions (roms/saves), not metadata (png/txt)
          final filteredExts = system.extensions.where((e) => !['png', 'txt', 'jpg', 'xml', 'json', 'pdf', 'htm', 'html', 'nomedia'].contains(e.toLowerCase())).toList();
          
          if (await _hasValidRoms(folderUri, filteredExts.isNotEmpty ? filteredExts : system.extensions)) {
            print('✅ SCAN: System ${system.id} confirmed in "$folderName"');
            matchedFolderUris.add(folderUri);
            foundSystemIds.add(system.id);
            
            String? bestSavePath;
            String? bestEmulatorId;

            // 1. Prioritize the 'default' emulator from JSON config
            final defaultEmu = systemConfig.emulators.where((e) => e.defaultEmulator).firstOrNull;
            if (defaultEmu != null) {
              for (final entry in standaloneDefaults.entries) {
                if (defaultEmu.uniqueId.contains(entry.key)) {
                  bestSavePath = entry.value;
                  bestEmulatorId = entry.key;
                  if (entry.key == 'dolphin') {
                    if (system.id == 'gc') bestSavePath = '${entry.value}/GC';
                    if (system.id == 'wii') bestSavePath = '${entry.value}/Wii';
                  }
                  break;
                }
              }
            }

            // 2. If no default match found, try other standalone emulators
            if (bestSavePath == null) {
              for (final entry in standaloneDefaults.entries) {
                if (systemConfig.emulators.any((e) => e.uniqueId.contains(entry.key))) {
                  bool exists = await _platform.invokeMethod<bool>('checkPathExists', {'path': entry.value}) ?? false;
                  if (exists) {
                    bestSavePath = entry.value;
                    bestEmulatorId = entry.key;
                    if (entry.key == 'dolphin') {
                        if (system.id == 'gc') bestSavePath = '${entry.value}/GC';
                        if (system.id == 'wii') bestSavePath = '${entry.value}/Wii';
                    }
                    break;
                  }
                }
              }
            }

            // 3. Fallback to RetroArch
            if (bestSavePath == null) {
              final ra = await getRetroArchPaths();
              bestSavePath = ra['saves'];
              bestEmulatorId = 'retroarch';
            }

            if (bestSavePath != null) {
              // QoL: Don't overwrite if the user has already configured this system manually
              final existingPath = await getSystemPath(system.id);
              if (existingPath == null) {
                await setSystemPath(system.id, bestSavePath);
                if (bestEmulatorId != null) await setSystemEmulator(system.id, bestEmulatorId);
                print('💾 SCAN: Persisted new system ${system.id} to $bestSavePath');
              } else {
                print('⏭️ SCAN: Skipping configuration for ${system.id} (already exists)');
              }
              foundSystemIds.add(system.id);
            }
            break; // Stop looking for systems for this folder once a match is found
          }
        }
      }
    }

    print('🏁 SCAN: Library-First scan complete. Found ${foundSystemIds.length} systems.');
    return foundSystemIds;
  }

  Future<bool> _hasValidRoms(String path, List<String> extensions) async {
    if (path.startsWith('content://')) {
       return await _platform.invokeMethod<bool>('hasFilesWithExtensions', {
         'uri': path,
         'extensions': extensions
       }) ?? false;
    } else {
      final lowerExts = extensions.map((e) => e.toLowerCase()).toSet();
      lowerExts.removeAll(['txt', 'bak', 'nomedia', 'tmp']);
      final dir = Directory(path);
      if (await dir.exists()) {
        try {
          await for (final e in dir.list(recursive: true).take(100)) { 
            if (e is File) {
              final ext = e.path.split('.').last.toLowerCase();
              if (lowerExts.contains(ext)) return true;
            }
          }
        } catch (_) {}
      }
    }
    return false;
  }
}
