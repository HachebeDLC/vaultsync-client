import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Callback signature for a launcher-channel method handler.
typedef LauncherChannelCallback = FutureOr<dynamic> Function(MethodCall call);

/// A per-isolate singleton that installs the ONE inbound
/// [MethodChannel.setMethodCallHandler] on `com.vaultsync.app/launcher` and
/// dispatches incoming calls to registered callbacks by [MethodCall.method].
///
/// A [MethodChannel] supports only one inbound handler per isolate. Before
/// this router existed, both `BackgroundSyncService` (which handles
/// `onEmulatorClosed`) and `connectivityProvider` (which handles
/// `onConnectivityChanged`) called `setMethodCallHandler` directly on this
/// same channel. Whichever registered last silently disabled the other, and
/// `connectivityProvider`'s `onDispose` called `setMethodCallHandler(null)`,
/// wiping out `BackgroundSyncService`'s handler too. Routing every caller
/// through this single owner fixes both problems: each caller registers a
/// callback for the method(s) it cares about, and unregistering one leaves
/// every other callback — for that method or any other — untouched.
class LauncherChannelRouter {
  LauncherChannelRouter._(this._channel) {
    _channel.setMethodCallHandler(_dispatch);
  }

  static LauncherChannelRouter? _instance;

  /// The shared per-isolate instance. Each isolate that touches this channel
  /// (the main isolate, and each WorkManager `callbackDispatcher` run) gets
  /// its own instance and its own inbound handler, since static state is not
  /// shared across isolates.
  factory LauncherChannelRouter() {
    return _instance ??= LauncherChannelRouter._(
      const MethodChannel('com.vaultsync.app/launcher'),
    );
  }

  /// Test-only: builds a router bound to an arbitrary channel, bypassing the
  /// singleton so tests can exercise the router without colliding with the
  /// real `com.vaultsync.app/launcher` channel or with each other.
  @visibleForTesting
  factory LauncherChannelRouter.forTesting(MethodChannel channel) {
    return LauncherChannelRouter._(channel);
  }

  /// Test-only: drops the singleton so the next [LauncherChannelRouter]
  /// call creates (and installs a handler for) a fresh instance.
  @visibleForTesting
  static void resetForTesting() {
    _instance = null;
  }

  final MethodChannel _channel;
  final Map<String, List<LauncherChannelCallback>> _callbacks = {};

  /// Registers [callback] to run whenever a call with [method] arrives.
  ///
  /// Returns a function that unregisters only this callback; every other
  /// callback registered for [method] (or any other method) keeps working.
  void Function() register(String method, LauncherChannelCallback callback) {
    final callbacks = _callbacks.putIfAbsent(method, () => []);
    callbacks.add(callback);
    return () {
      callbacks.remove(callback);
      // Only drop the map entry if it is still this list: a stale second call
      // must not remove a newer list created by a later register().
      if (callbacks.isEmpty && identical(_callbacks[method], callbacks)) {
        _callbacks.remove(method);
      }
    };
  }

  Future<dynamic> _dispatch(MethodCall call) async {
    final callbacks = _callbacks[call.method];
    if (callbacks == null || callbacks.isEmpty) return null;

    dynamic result;
    // Copy the list: a callback could register/unregister during dispatch.
    for (final callback in List<LauncherChannelCallback>.from(callbacks)) {
      try {
        result = await callback(call);
      } catch (e, st) {
        developer.log(
          'LAUNCHER_CHANNEL: handler for "${call.method}" threw',
          name: 'VaultSync',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    }
    return result;
  }
}
