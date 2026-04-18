import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:vaultsync_client/core/services/connectivity_provider.dart';

class MockConnectivity extends Mock implements Connectivity {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('ConnectivityProvider Non-Android', () {
    test('emits connectivity results', () async {
      // On Linux, connectivity is hardcoded to always-connected (no NetworkManager).
      // This test covers macOS/Windows where the real stream is used.
      if (Platform.isLinux) return;

      final container = ProviderContainer(
        overrides: [
          connectivityInstanceProvider.overrideWithValue(mockConnectivity),
        ],
      );

      final sub = container.listen(connectivityProvider, (_, __) {});

      controller.add([ConnectivityResult.wifi]);
      await Future.delayed(Duration.zero);
      expect(container.read(connectivityProvider).value, contains(ConnectivityResult.wifi));

      controller.add([ConnectivityResult.none]);
      await Future.delayed(Duration.zero);
      expect(container.read(connectivityProvider).value, contains(ConnectivityResult.none));

      sub.close();
    });

    test('isOnlineProvider reflects status', () async {
      if (Platform.isLinux) return;

      final container = ProviderContainer(
        overrides: [
          connectivityInstanceProvider.overrideWithValue(mockConnectivity),
        ],
      );

      controller.add([ConnectivityResult.wifi]);
      await container.read(connectivityProvider.future);
      expect(container.read(isOnlineProvider), isTrue);

      controller.add([ConnectivityResult.none]);
      await Future.delayed(Duration.zero);
      expect(container.read(isOnlineProvider), isFalse);
    });
  });

  group('ConnectivityProvider Linux', () {
    test('always reports online (no NetworkManager required)', () async {
      if (!Platform.isLinux) return;

      final container = ProviderContainer();
      await container.read(connectivityProvider.future);
      expect(container.read(isOnlineProvider), isTrue);
    });
  });

  group('ConnectivityProvider Android transitions', () {
    // Note: We can't easily force Platform.isAndroid to true in a standard VM test,
    // but we can test the logic by ensuring the non-android path handles transitions correctly.
    // Transition tests are mostly covered by the tests above as they use the stream.
  });
}
