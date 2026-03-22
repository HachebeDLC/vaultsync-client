import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';
import '../../emulation/data/emulator_repository.dart';
import '../../emulation/domain/emulator_config.dart';
import '../data/dart_file_scanner.dart';
import '../../../core/utils/platform_utils.dart';

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
    'ppsspp': '/storage/emulated/0/PSP/SAVEDATA',
    'dolphin': '/storage/emulated/0/Android/data/org.dolphinemu.dolphinemu/files',
    'citra': '/storage/emulated/0/Citra',
    'yuzu': '/storage/emulated/0/Android/data/org.yuzu.yuzu_emu/files',
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

  Future<String?> getSystemPath(String systemId) async {
    final paths = await getAllSystemPaths();
    return paths[systemId];
  }

  Future<void> setSystemPath(String systemId, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("system_path_$systemId", path);
    _cachedPaths = null;
    await prefs.setInt("storage_version", (prefs.getInt("storage_version") ?? 0) + 1);
  }

  Future<String?> getSystemEmulator(String systemId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("system_emulator_$systemId");
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

  Future<String> suggestSavePath(EmulatorInfo emulator, String systemId) async {
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) return _getEmuDeckConfig(emuDeckSaves, systemId)['path']!;
    if (Platform.isWindows || Platform.isLinux) {
      for (final entry in standaloneDefaults.entries) {
        if (emulator.uniqueId.contains(entry.key)) {
          final desktopPath = _getDesktopDefault(entry.key, systemId);
          if (desktopPath != null) return desktopPath;
        }
      }
      return '${_getDesktopHome()}/RetroArch/saves';
    }
    return standaloneDefaults[systemId.toLowerCase()] ?? '/storage/emulated/0/RetroArch/saves';
  }

  Future<String> suggestSavePathById(String systemId) async {
    final emuDeckSaves = await getEmuDeckSavesPath();
    if (emuDeckSaves != null) return _getEmuDeckConfig(emuDeckSaves, systemId)['path']!;
    if (Platform.isWindows || Platform.isLinux) {
      return '${_getDesktopHome()}/RetroArch/saves';
    }
    return standaloneDefaults[systemId.toLowerCase()] ?? '/storage/emulated/0/RetroArch/saves';
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
          if (ext.isNotEmpty && extSet.contains(ext)) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Map<String, String> _getEmuDeckConfig(String emuDeckSaves, String systemId) {
    final base = emuDeckSaves;
    final sid = systemId.toLowerCase();
    String findFolder(String parent, String target) {
      try {
        final dir = Directory(parent);
        if (!dir.existsSync()) return "$parent/$target";
        for (final entity in dir.listSync()) {
          final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.toLowerCase() == target.toLowerCase()) return entity.path;
        }
      } catch (_) {}
      return "$parent/$target";
    }

    String wikiPath(String emulator, {String sub = "saves"}) {
       final root = findFolder(base, emulator);
       if (sub.isEmpty) return root;
       return "$root/$sub";
    }

    final Map<String, (String, String, String)> emuMap = {
      "ps2": (wikiPath("pcsx2"), "ps2.pcsx2.desktop", "ps2.ra.pcsx2"),
      "psx": (wikiPath("duckstation"), "ps1.duckstation.desktop", "psx.ra.swanstation"),
      "ps1": (wikiPath("duckstation"), "ps1.duckstation.desktop", "psx.ra.swanstation"),
      "psp": (wikiPath("ppsspp"), "psp.ppsspp.desktop", "psp.ra.ppsspp"),
      "gc": (wikiPath("dolphin", sub: "GC"), "gc.dolphin.desktop", "gc.ra.dolphin"),
      "wii": (wikiPath("dolphin", sub: "Wii"), "wii.dolphin.desktop", "wii.ra.dolphin"),
      "3ds": (wikiPath("citra"), "3ds.citra.desktop", "3ds.ra.citra"),
      "nds": (wikiPath("melonds"), "ds.melonds.desktop", "ds.ra.melondsds"),
      "ds": (wikiPath("melonds"), "ds.melonds.desktop", "ds.ra.melondsds"),
      "gba": (wikiPath("mgba"), "gba.mgba.desktop", "gba.ra.mgba"),
      "gbc": (wikiPath("retroarch"), "gbc.mgba.desktop", "gbc.ra.sameboy"),
      "gb": (wikiPath("retroarch"), "gb.mgba.desktop", "gb.ra.sameboy"),
      "wiiu": (wikiPath("Cemu"), "wiiu.cemu.desktop", ""),
      "ps3": (wikiPath("rpcs3"), "ps3.rpcs3.desktop", ""),
      "ps4": (wikiPath("shadps4"), "ps4.shadps4.desktop", ""),
      "vita": (wikiPath("Vita3K"), "vita.vita3k.desktop", ""),
      "xbox": (wikiPath("xemu"), "xbox.xemu.desktop", ""),
      "xbox360": (wikiPath("xenia"), "xbox360.xenia.desktop", ""),
      "scummvm": (wikiPath("scummvm"), "scummvm.scummvm.desktop", ""),
      "primehack": (wikiPath("primehack", sub: "GC"), "primehack.dolphin.desktop", ""),
      "mame": (wikiPath("MAME"), "mame.mame.desktop", "mame.ra.mame"),
      "arcade": (wikiPath("MAME"), "arcade.mame.desktop", "mame.ra.fbneo"),
      "n64": (wikiPath("retroarch"), "n64.rmg.desktop", "n64.ra.mupen64plus_next_gles3"),
      "dc": (wikiPath("flycast"), "dc.flycast.desktop", "dc.ra.flycast"),
      "dreamcast": (wikiPath("flycast"), "dc.flycast.desktop", "dc.ra.flycast"),
      "model2": (wikiPath("model2", sub: ""), "model2.emulator.desktop", ""),
      "model3": (wikiPath("supermodel"), "model3.supermodel.desktop", ""),
      "jag": (wikiPath("bigpemu"), "jag.bigpemu.desktop", ""),
      "azahar": (wikiPath("azahar"), "3ds.azahar.android", ""),
      "switch": (wikiPath("yuzu"), "switch.yuzu.desktop", "switch.ryujinx.desktop"),
      "eden": (wikiPath("yuzu"), "switch.yuzu.desktop", "switch.ryujinx.desktop"),
    };

    final config = emuMap[sid];
    if (config != null) {
      if (sid == "switch" || sid == "eden") {
        if (Directory(wikiPath("yuzu")).existsSync()) return { "path": wikiPath("yuzu"), "emulatorId": "switch.yuzu.desktop" };
        return { "path": wikiPath("ryujinx"), "emulatorId": "switch.ryujinx.desktop" };
      }
      if (Directory(config.$1).existsSync() || config.$3.isEmpty) {
        return { "path": config.$1, "emulatorId": config.$2 };
      }
      return { "path": wikiPath("retroarch"), "emulatorId": config.$3 };
    }

    final Map<String, String> retroArchCores = {
      'snes': 'snes.ra.snes9x', 'nes': 'nes.ra.mesen', 'genesis': 'genesis.ra.genesis_plus_gx',
      'md': 'genesis.ra.genesis_plus_gx', 'megadrive': 'genesis.ra.genesis_plus_gx',
      'ms': 'genesis.ra.genesis_plus_gx', 'mastersystem': 'genesis.ra.genesis_plus_gx',
      'gg': 'genesis.ra.genesis_plus_gx', 'gamegear': 'genesis.ra.genesis_plus_gx',
      'scd': 'genesis.ra.genesis_plus_gx', 'segacd': 'genesis.ra.genesis_plus_gx',
      '32x': '32x.ra.picodrive', 'amiga': 'amiga.ra.puae', 'c64': 'c64.ra.vice',
      'cpc': 'cpc.ra.cap32', '2600': '2600.ra.stella', 'lynx': 'lynx.ra.handy',
      'doom': 'doom.ra.prboom', 'dos': 'dos.ra.dosbox_pure', 'easyrpg': 'easyrpg.ra.easyrpg',
      'fbneo': 'fbneo.ra.fbneo', 'intv': 'intellivision.ra.freeintv',
      'pc98': 'pc98.ra.neko_project_ii_kai', 'pico8': 'pico8.ra.pico8',
      'pce': 'pce.ra.mednafen_pce_fast', 'tg16': 'pce.ra.mednafen_pce_fast',
      'tgcd': 'pce.ra.mednafen_pce_fast', 'sat': 'saturn.ra.mednafen_saturn',
      'saturn': 'saturn.ra.mednafen_saturn', 'vb': 'virtualboy.ra.mednafen_vb',
      '3do': '3do.ra.opera', 'zxspectrum': 'zxspectrum.ra.fuse',
      'ws': 'ws.ra.mednafen_wswan', 'wsc': 'ws.ra.mednafen_wswan',
      'ngp': 'ngp.ra.mednafen_ngp', 'ngpc': 'ngp.ra.mednafen_ngp', 'x68000': 'x68000.ra.px68k',
    };
    return { 'path': wikiPath('retroarch'), 'emulatorId': retroArchCores[sid] ?? '' };
  }

  Future<String> getEffectivePath(String systemId) async {
    final rawPath = await getSystemPath(systemId);
    if (rawPath == null) return await suggestSavePathById(systemId);
    if (!Platform.isAndroid) return rawPath;
    final androidVersion = await _getAndroidVersion();
    final prefs = await SharedPreferences.getInstance();
    final useShizuku = prefs.getBool('use_shizuku') ?? false;
    if (useShizuku && androidVersion >= 34 && rawPath.toLowerCase().contains('android/data')) return 'shizuku://$rawPath';
    if (rawPath.toLowerCase().contains('android/data')) {
       final persistedUri = prefs.getString("saf_uri_$rawPath");
       if (persistedUri != null) return persistedUri;
    }
    return _convertToPosix(rawPath);
  }

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
          final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase();
          return name == system.system.id.toLowerCase() || name == system.system.name.toLowerCase() || system.system.folders.map((f) => f.toLowerCase()).contains(name);
        });
        for (final d in matchingDirs) {
          if (await _hasValidRoms(d, system.system.extensions)) {
            if (emuDeckSaves != null) {
              final config = _getEmuDeckConfig(emuDeckSaves.path, system.system.id);
              results.add({'systemId': system.system.id, 'path': config['path']!, 'emulatorId': config['emulatorId']!});
            } else {
              results.add({'systemId': system.system.id, 'path': d.path});
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

  Future<String?> getSwitchSavePathForGame(String systemId, String gameId) async => await getEffectivePath(systemId);

  Future<Map<String, String>> getRetroArchPaths() async {
    final saves = await getSystemPath('retroarch') ?? await suggestSavePathById('retroarch');
    final states = (saves.endsWith('/saves')) ? '${saves.substring(0, saves.length - 6)}/states' : '$saves/states';
    return {'saves': saves, 'states': states};
  }
}
