import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/launcher_channel_router.dart';
import 'sync_service.dart';
import 'system_path_service.dart';

final backgroundSyncServiceProvider = Provider<BackgroundSyncService>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  final service = BackgroundSyncService(syncService, pathService);
  ref.onDispose(service.dispose);
  return service;
});

/// Preference key gating both the live (process-alive) exit detection and the
/// catch-up path — set by the "Sync on Game Exit" toggle in Settings.
const String kAutoSyncOnExitPrefKey = 'auto_sync_on_exit';

/// Checkpoint (epoch millis) up to which we've already asked the native side
/// for emulator exits. Catch-up resumes from here instead of re-processing
/// exits we already handled.
const String kLastExitCheckMsPrefKey = 'last_exit_check_ms';

/// How far back to look the very first time there is no checkpoint yet.
const Duration kExitCatchUpDefaultLookback = Duration(minutes: 15);

/// Hard cap on how far back catch-up ever looks. The checkpoint only advances
/// once every sync in a run succeeded, so an exit whose sync keeps failing
/// (server down, system misconfigured) is retried each run — but not forever.
const Duration kExitCatchUpMaxLookback = Duration(hours: 24);

class BackgroundSyncService {
  final SyncService _syncService;
  final SystemPathService _pathService;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  /// Overridable so unit tests (which run on the host OS, never on Android)
  /// can exercise the Android-only catch-up/monitoring logic without a real
  /// device. Defaults to the real platform check everywhere else.
  final bool _isAndroid;

  bool _catchUpInProgress = false;
  void Function()? _unregister;

  BackgroundSyncService(this._syncService, this._pathService,
      {@visibleForTesting bool? isAndroidOverride})
      : _isAndroid = isAndroidOverride ?? Platform.isAndroid {
    // Routed through LauncherChannelRouter: this channel also carries
    // connectivityProvider's 'onConnectivityChanged' calls, and a
    // MethodChannel only supports one inbound handler per isolate — calling
    // setMethodCallHandler here directly would silently disable (or be wiped
    // out by) connectivityProvider's handler.
    _unregister = LauncherChannelRouter().register('onEmulatorClosed', _handleMethodCall);
  }

  /// Unregisters this service's launcher-channel callback. Called when the
  /// owning provider is disposed (e.g. the WorkManager background isolate's
  /// [ProviderContainer] at the end of each task) so a later task run in the
  /// same isolate doesn't stack a second callback on top of this one.
  void dispose() {
    _unregister?.call();
    _unregister = null;
  }

  // Canonical map of emulator package -> VaultSync system id.
  // System ids are the file names under assets/systems/*.json (e.g. 'nds',
  // 'dc') — NOT the emulator's own vernacular ('ds', 'dreamcast'), which
  // don't exist as systems and silently dropped every sync for those
  // packages. 'retroarch' has no json of its own; sync_service.dart
  // normalizes it case-insensitively (see SyncService._resolveEffectivePaths
  // / _cloudNamespaceFor) into its saves+states RetroArch paths.
  static const Map<String, String> packageToSystem = {
    // PS2
    'xyz.aethersx2.android': 'ps2',
    'xyz.nethersx2.android': 'ps2',
    'xyz.aethersx2.custom': 'ps2',
    'xyz.aethersx2.tturnip': 'ps2',
    'com.aether.sx2': 'ps2',
    // Switch
    'org.yuzu.yuzu_emu': 'switch',
    'org.yuzu.yuzu_emu.early_access': 'switch',
    'dev.eden.eden_emulator': 'switch',
    // PS1
    'com.github.stenzek.duckstation': 'ps1',
    // GameCube / Wii
    'org.dolphinemu.dolphinemu': 'wii',
    'com.dolphin.emulator': 'wii',
    // DS — canonical system id is 'nds' (assets/systems/nds.json).
    'me.magnum.melonds': 'nds',
    'me.magnum.melonds.nightly': 'nds',
    // 3DS
    'org.citra.citra_emu': '3ds',
    'com.citra.emu': '3ds',
    'org.citra.emu': '3ds',
    'org.azahar_emu.azahar': '3ds',
    // PSP
    'org.ppsspp.ppsspp': 'psp',
    'org.ppsspp.ppssppgold': 'psp',
    // Dreamcast — canonical system id is 'dc' (assets/systems/dc.json).
    'com.flycast.emulator': 'dc',
    // RetroArch family — single 'retroarch' system covers saves + states.
    'com.retroarch': 'retroarch',
    'com.retroarch.aarch64': 'retroarch',
    'com.retroarch.ra32': 'retroarch',
    'org.libretro.RetroArch': 'retroarch',
  };

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onEmulatorClosed') {
      final String package = call.arguments;
      final success = await _syncClosedPackage(package, logPrefix: 'BACKGROUND');
      if (success) {
        // The live path just handled this exit — advance the checkpoint so
        // catch-up doesn't redo it the next time it runs.
        await _saveCheckpoint(DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  /// Syncs the emulator system mapped to [package], if any. Returns true if
  /// a sync was attempted and completed without throwing (false if there is
  /// no mapping, or the sync itself failed).
  Future<bool> _syncClosedPackage(String package,
      {required String logPrefix}) async {
    final systemId = packageToSystem[package];

    developer.log(
        '$logPrefix: Emulator closed ($package). Auto-syncing $systemId...',
        name: 'VaultSync',
        level: 800);

    if (systemId == null) return false;

    final path = await _pathService.getEffectivePath(systemId);
    final systems = await _pathService.getEmulatorRepository().loadSystems();
    final config = systems.where((s) => s.system.id == systemId).firstOrNull;

    try {
      await _syncService.syncSpecificSystem(
        systemId,
        path,
        ignoredFolders: config?.system.ignoredFolders,
        onProgress: (msg) =>
            developer.log('$logPrefix: $msg', name: 'VaultSync', level: 800),
      );
      return true;
    } catch (e) {
      developer.log('$logPrefix SYNC FAILED',
          name: 'VaultSync', level: 1000, error: e);
      return false;
    }
  }

  /// Catches up on emulator exits that happened while the app process was
  /// dead — e.g. VaultSync got killed by the low-memory killer while a game
  /// was running, so the live polling loop in AutomationEngine never saw the
  /// exit, and it never surfaced through 'onEmulatorClosed'.
  ///
  /// Reads the `last_exit_check_ms` checkpoint (defaulting to now minus
  /// [kExitCatchUpDefaultLookback] the first time it runs), asks the native
  /// side for every monitored-package exit since then, and syncs each one.
  /// One failing sync does not stop the others. The checkpoint only advances
  /// when every sync succeeded, so a failed one (e.g. the server was down) is
  /// retried on the next run, within [kExitCatchUpMaxLookback]. Returns the
  /// number of exits handled (regardless of whether their sync succeeded).
  Future<int> catchUpMissedExits() async {
    if (!_isAndroid) return 0;
    if (_catchUpInProgress) {
      developer.log('CATCHUP: Already in progress, skipping re-entrant call',
          name: 'VaultSync', level: 800);
      return 0;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(kAutoSyncOnExitPrefKey) ?? false)) return 0;

    _catchUpInProgress = true;
    try {
      final nowTime = DateTime.now();
      final now = nowTime.millisecondsSinceEpoch;
      final floorMs = nowTime.subtract(kExitCatchUpMaxLookback).millisecondsSinceEpoch;
      final storedMs = prefs.getInt(kLastExitCheckMsPrefKey) ??
          nowTime.subtract(kExitCatchUpDefaultLookback).millisecondsSinceEpoch;
      final sinceMs = storedMs < floorMs ? floorMs : storedMs;

      List<dynamic> rawExits;
      try {
        rawExits = await _platform.invokeMethod<List<dynamic>>(
              'getEmulatorExitsSince',
              {
                'packages': packageToSystem.keys.toList(),
                'sinceMs': sinceMs,
              },
            ) ??
            const [];
      } catch (e) {
        developer.log('CATCHUP: Native call failed',
            name: 'VaultSync', level: 1000, error: e);
        return 0;
      }

      developer.log(
          'CATCHUP: Found ${rawExits.length} missed exit(s) since $sinceMs',
          name: 'VaultSync',
          level: 800);

      var allSucceeded = true;
      for (final raw in rawExits) {
        final map = Map<Object?, Object?>.from(raw as Map);
        final package = map['package'] as String?;
        if (package == null) continue;
        if (!await _syncClosedPackage(package, logPrefix: 'CATCHUP')) {
          allSucceeded = false;
        }
      }

      if (allSucceeded) {
        await _saveCheckpoint(now);
      } else {
        developer.log(
            'CATCHUP: At least one sync failed — keeping checkpoint so the next run retries',
            name: 'VaultSync',
            level: 900);
      }
      return rawExits.length;
    } finally {
      _catchUpInProgress = false;
    }
  }

  Future<void> _saveCheckpoint(int epochMs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kLastExitCheckMsPrefKey, epochMs);
  }

  Future<void> startMonitoring(
      {Duration interval = const Duration(seconds: 15)}) async {
    if (_isAndroid) {
      await _platform.invokeMethod('startMonitoring', {
        'packages': packageToSystem.keys.toList(),
        'interval': interval.inMilliseconds,
      });
    }
  }

  Future<void> stopMonitoring() async {
    if (_isAndroid) {
      await _platform.invokeMethod('stopMonitoring');
    }
  }
}
