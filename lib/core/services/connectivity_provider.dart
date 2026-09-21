import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'launcher_channel_router.dart';

/// Provider for the Connectivity instance to allow mocking in tests.
final connectivityInstanceProvider = Provider<Connectivity>((ref) {
  return Connectivity();
});

/// StreamProvider that listens to connectivity changes.
final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  if (Platform.isAndroid) {
    final controller = StreamController<List<ConnectivityResult>>();
    const platform = MethodChannel('com.vaultsync.app/launcher');

    // Initial status
    platform.invokeMethod<bool>('isOnline').then((online) {
      if (!controller.isClosed) {
        controller.add(online == true ? [ConnectivityResult.wifi] : [ConnectivityResult.none]);
      }
    });

    // Routed through LauncherChannelRouter: this channel also carries
    // BackgroundSyncService's 'onEmulatorClosed' calls, and a MethodChannel
    // only supports one inbound handler per isolate — calling
    // setMethodCallHandler here directly would silently disable (or, via
    // onDispose below, wipe out) BackgroundSyncService's handler.
    final unregister = LauncherChannelRouter().register('onConnectivityChanged', (call) async {
      final bool isOnline = call.arguments;
      if (!controller.isClosed) {
        controller.add(isOnline ? [ConnectivityResult.wifi] : [ConnectivityResult.none]);
      }
    });

    ref.onDispose(() {
      unregister();
      controller.close();
    });

    return controller.stream;
  } else if (Platform.isLinux) {
    // connectivity_plus on Linux requires NetworkManager via DBus, which is not
    // available on all Linux environments (Steam Deck, minimal WMs, etc.).
    // Assume always-connected and let individual requests handle network errors.
    return Stream.value([ConnectivityResult.wifi]);
  } else {
    final connectivity = ref.watch(connectivityInstanceProvider);
    return connectivity.onConnectivityChanged;
  }
});

/// Provider that returns true if the device has an active network connection.
final isOnlineProvider = Provider<bool>((ref) {
  final connectivity = ref.watch(connectivityProvider).value;
  if (connectivity == null || connectivity.isEmpty) return false;
  
  // Return true if any of the results are not 'none'
  return connectivity.any((result) => result != ConnectivityResult.none);
});

/// Resolves the real connectivity state, waiting for it instead of racing it.
///
/// [isOnlineProvider] reads `ref.watch(connectivityProvider).value`
/// synchronously. On Android, `connectivityProvider`'s first value arrives
/// asynchronously from `platform.invokeMethod('isOnline')`. In a fresh
/// [ProviderContainer] — always the case in the WorkManager background
/// isolate (see `callbackDispatcher` in `main.dart`) — a synchronous read
/// happens before that first value exists, `.value` is null, and
/// [isOnlineProvider] incorrectly reports false. Measured on-device: the
/// native `isOnline` call landed at 18:48:24.314 and the very next native
/// call (issued right after the synchronous read) at .325 — the decision
/// was made before the answer existed. That silently queued 1453 files for
/// offline upload that a real network connection could have sent right away.
///
/// This awaits [connectivityProvider]'s first real emission instead, with a
/// [timeout] safety net.
///
/// On timeout or error this returns `true` (assume online). Wrongly
/// assuming offline silently queues everything and uploads nothing — the
/// bug above — while wrongly assuming online just makes the requests fail
/// through the existing error handling, which is the safer failure mode.
Future<bool> resolveIsOnline(Ref ref, {Duration timeout = const Duration(seconds: 5)}) async {
  try {
    final result = await ref.read(connectivityProvider.future).timeout(timeout);
    return result.any((r) => r != ConnectivityResult.none);
  } catch (e, st) {
    developer.log(
      'CONNECTIVITY: resolveIsOnline timed out or failed — assuming ONLINE',
      name: 'VaultSync',
      level: 900,
      error: e,
      stackTrace: st,
    );
    return true;
  }
}

/// Provider to track if the user has manually dismissed the offline banner.
/// Resets when the device becomes online.
final isBannerDismissedProvider = StateProvider<bool>((ref) {
  ref.listen<bool>(isOnlineProvider, (previous, next) {
    if (next == true) {
      ref.controller.state = false;
    }
  });
  return false;
});

/// Combined provider to determine if the offline banner should be visible.
final showOfflineBannerProvider = Provider<bool>((ref) {
  final isOnline = ref.watch(isOnlineProvider);
  final isDismissed = ref.watch(isBannerDismissedProvider);
  return !isOnline && !isDismissed;
});
