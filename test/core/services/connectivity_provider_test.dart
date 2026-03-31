import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:vaultsync_client/core/services/connectivity_provider.dart';

class MockConnectivity extends Mock implements Connectivity {}

void main() {
  late MockConnectivity mockConnectivity;
  late StreamController<List<ConnectivityResult>> controller;

  setUp(() {
    mockConnectivity = MockConnectivity();
    controller = StreamController<List<ConnectivityResult>>();
    when(() => mockConnectivity.onConnectivityChanged).thenAnswer((_) => controller.stream);
  });

  tearDown(() {
    controller.close();
  });

  test('connectivityProvider should emit connectivity results', () async {
    final container = ProviderContainer(
      overrides: [
        connectivityInstanceProvider.overrideWithValue(mockConnectivity),
      ],
    );

    final sub = container.listen(connectivityProvider, (_, __) {});
    
    // First emission
    controller.add([ConnectivityResult.wifi]);
    await Future.delayed(Duration.zero);
    expect(container.read(connectivityProvider).value, contains(ConnectivityResult.wifi));
    
    // Second emission
    controller.add([ConnectivityResult.none]);
    await Future.delayed(Duration.zero);
    expect(container.read(connectivityProvider).value, contains(ConnectivityResult.none));
    
    sub.close();
  });

  test('isOnlineProvider should return true when connected to wifi', () async {
    final container = ProviderContainer(
      overrides: [
        connectivityInstanceProvider.overrideWithValue(mockConnectivity),
      ],
    );

    controller.add([ConnectivityResult.wifi]);
    await container.read(connectivityProvider.future);
    
    expect(container.read(isOnlineProvider), isTrue);
  });

  test('isOnlineProvider should return false when none', () async {
    final container = ProviderContainer(
      overrides: [
        connectivityInstanceProvider.overrideWithValue(mockConnectivity),
      ],
    );

    controller.add([ConnectivityResult.none]);
    await container.read(connectivityProvider.future);
    
    expect(container.read(isOnlineProvider), isFalse);
  });
}
