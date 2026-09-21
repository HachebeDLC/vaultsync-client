import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/core/services/launcher_channel_router.dart';

/// Simulates a native -> Flutter call arriving on [channel], the way real
/// platform code would invoke whatever handler is currently installed via
/// `MethodChannel.setMethodCallHandler`. Returns the decoded result, or
/// rethrows if the handler replied with an error envelope.
Future<dynamic> _simulateIncomingCall(MethodChannel channel, MethodCall call) async {
  final ByteData message = channel.codec.encodeMethodCall(call);
  ByteData? response;
  var completed = false;
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel.name, message, (ByteData? reply) {
    response = reply;
    completed = true;
  });
  expect(completed, isTrue, reason: 'no handler replied to ${call.method}');
  final reply = response;
  if (reply == null) return null;
  return channel.codec.decodeEnvelope(reply);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LauncherChannelRouter (isolated test channel)', () {
    late MethodChannel channel;
    late LauncherChannelRouter router;

    setUp(() {
      // A dedicated channel per test keeps this suite from touching the
      // real 'com.vaultsync.app/launcher' name or the process-wide
      // singleton.
      channel = const MethodChannel('test.launcher_channel_router');
      router = LauncherChannelRouter.forTesting(channel);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(channel.name, null);
    });

    test('both handlers receive their calls regardless of registration order', () async {
      final receivedA = <dynamic>[];
      final receivedB = <dynamic>[];

      // Register the second consumer's method before the first's, mirroring
      // that connectivityProvider and BackgroundSyncService can install in
      // either order without one disabling the other.
      router.register('onConnectivityChanged', (call) async {
        receivedB.add(call.arguments);
      });
      router.register('onEmulatorClosed', (call) async {
        receivedA.add(call.arguments);
      });

      await _simulateIncomingCall(channel, const MethodCall('onEmulatorClosed', 'org.yuzu.yuzu_emu'));
      await _simulateIncomingCall(channel, const MethodCall('onConnectivityChanged', true));

      expect(receivedA, ['org.yuzu.yuzu_emu']);
      expect(receivedB, [true]);
    });

    test('unregistering one callback leaves the other working', () async {
      final receivedA = <dynamic>[];
      final receivedB = <dynamic>[];

      final unregisterA = router.register('onEmulatorClosed', (call) async {
        receivedA.add(call.arguments);
      });
      router.register('onConnectivityChanged', (call) async {
        receivedB.add(call.arguments);
      });

      unregisterA();

      await _simulateIncomingCall(channel, const MethodCall('onEmulatorClosed', 'org.yuzu.yuzu_emu'));
      await _simulateIncomingCall(channel, const MethodCall('onConnectivityChanged', true));

      expect(receivedA, isEmpty, reason: 'unregistered callback must not fire');
      expect(receivedB, [true], reason: 'the other callback must be unaffected');
    });

    test('unregistering does not disturb a second callback on the SAME method', () async {
      final firstCalls = <dynamic>[];
      final secondCalls = <dynamic>[];

      final unregisterFirst = router.register('onEmulatorClosed', (call) async {
        firstCalls.add(call.arguments);
      });
      router.register('onEmulatorClosed', (call) async {
        secondCalls.add(call.arguments);
      });

      unregisterFirst();
      await _simulateIncomingCall(channel, const MethodCall('onEmulatorClosed', 'pkg'));

      expect(firstCalls, isEmpty);
      expect(secondCalls, ['pkg']);
    });

    test('an unknown method returns null and does not throw', () async {
      router.register('onEmulatorClosed', (call) async => 'handled');

      final result = await _simulateIncomingCall(channel, const MethodCall('somethingElse', null));

      expect(result, isNull);
    });

    test('a throwing callback does not break dispatch for other methods', () async {
      router.register('onEmulatorClosed', (call) async => throw Exception('boom'));
      final receivedB = <dynamic>[];
      router.register('onConnectivityChanged', (call) async {
        receivedB.add(call.arguments);
      });

      // Must not throw out of the dispatch, and must not prevent the next
      // call (to a different method) from being handled normally.
      await _simulateIncomingCall(channel, const MethodCall('onEmulatorClosed', 'pkg'));
      await _simulateIncomingCall(channel, const MethodCall('onConnectivityChanged', false));

      expect(receivedB, [false]);
    });
  });

  group('LauncherChannelRouter singleton', () {
    tearDown(() {
      LauncherChannelRouter.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('com.vaultsync.app/launcher', null);
    });

    test('repeated construction returns the same per-isolate instance', () {
      LauncherChannelRouter.resetForTesting();
      final first = LauncherChannelRouter();
      final second = LauncherChannelRouter();
      expect(identical(first, second), isTrue);
    });
  });

  test('a stale second unregister does not remove a newer registration', () async {
    const ch = MethodChannel('test/launcher_router_stale_unregister');
    final router = LauncherChannelRouter.forTesting(ch);
    final unregisterA = router.register('m', (_) async => 'a');
    unregisterA();
    router.register('m', (_) async => 'b');
    unregisterA(); // stale, must be a no-op

    final reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(ch.name, const StandardMethodCodec().encodeMethodCall(const MethodCall('m')), (_) {});
    expect(const StandardMethodCodec().decodeEnvelope(reply!), 'b');
  });
}
