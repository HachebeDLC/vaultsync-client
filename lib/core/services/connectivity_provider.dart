import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    platform.setMethodCallHandler((call) async {
      if (call.method == 'onConnectivityChanged') {
        final bool isOnline = call.arguments;
        if (!controller.isClosed) {
          controller.add(isOnline ? [ConnectivityResult.wifi] : [ConnectivityResult.none]);
        }
      }
    });

    ref.onDispose(() {
      platform.setMethodCallHandler(null);
      controller.close();
    });

    return controller.stream;
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
