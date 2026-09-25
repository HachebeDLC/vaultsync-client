import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final batteryOptimizationServiceProvider =
    Provider<BatteryOptimizationService>((ref) => BatteryOptimizationService());

/// Wraps the native "ignore battery optimizations" allowlist check/request
/// used by the "sync on game exit" foreground service.
///
/// Evidence from a real device (Retroid Pocket Nova, Android 13): the
/// low-memory killer killed VaultSync — including its foreground service —
/// while a game was running. The system then tried to restart the service
/// via START_STICKY but immediately stopped it again
/// (`am_stop_idle_service` / "Stopping service due to app idle"), and
/// `dumpsys deviceidle whitelist` did not include the app. Apps on the
/// battery-optimization allowlist are exempt from that idle stop, so this
/// service lets Settings ask the user to add VaultSync to it.
class BatteryOptimizationService {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  final bool _isAndroid;
  final Future<bool> Function() _isIgnoringBatteryOptimizations;
  final Future<bool> Function() _requestIgnoreBatteryOptimizations;

  BatteryOptimizationService({
    @visibleForTesting bool? isAndroidOverride,
    @visibleForTesting
    Future<bool> Function()? isIgnoringBatteryOptimizationsOverride,
    @visibleForTesting
    Future<bool> Function()? requestIgnoreBatteryOptimizationsOverride,
  })  : _isAndroid = isAndroidOverride ?? Platform.isAndroid,
        _isIgnoringBatteryOptimizations =
            isIgnoringBatteryOptimizationsOverride ?? _defaultIsIgnoring,
        _requestIgnoreBatteryOptimizations =
            requestIgnoreBatteryOptimizationsOverride ?? _defaultRequest;

  static Future<bool> _defaultIsIgnoring() async {
    try {
      return await _platform
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> _defaultRequest() async {
    try {
      return await _platform
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Whether the app is currently exempt from battery-optimization idle
  /// stops. Always false off Android.
  Future<bool> isIgnoringBatteryOptimizations() {
    if (!_isAndroid) return Future.value(false);
    return _isIgnoringBatteryOptimizations();
  }

  /// Launches the system's "ignore battery optimizations" request flow.
  /// Returns whether an intent was actually launched.
  Future<bool> requestIgnoreBatteryOptimizations() {
    if (!_isAndroid) return Future.value(false);
    return _requestIgnoreBatteryOptimizations();
  }

  /// Ensures the app is exempt from battery-optimization idle stops,
  /// prompting the user first via [confirm] (expected to show a rationale
  /// dialog and resolve to whether they agreed).
  ///
  /// Does nothing on non-Android platforms or when already exempt. Never
  /// prompts on every app start — callers are expected to invoke this only
  /// from an explicit user action, such as turning "sync on game exit" on.
  Future<void> ensureExempt(
      {required Future<bool> Function() confirm}) async {
    if (!_isAndroid) return;
    final alreadyExempt = await isIgnoringBatteryOptimizations();
    if (alreadyExempt) return;

    final accepted = await confirm();
    if (!accepted) return;

    await requestIgnoreBatteryOptimizations();
  }
}
