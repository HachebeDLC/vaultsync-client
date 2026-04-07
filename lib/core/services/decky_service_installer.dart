import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DeckyBridgeStatus { unknown, notInstalled, stopped, running, installing }

final deckyServiceInstallerProvider =
    AsyncNotifierProvider<DeckyServiceInstaller, DeckyBridgeStatus>(
        DeckyServiceInstaller.new);

class DeckyServiceInstaller extends AsyncNotifier<DeckyBridgeStatus> {
  static const _serviceName = 'vaultsync-bridge';
  static const _serviceFile =
      '.config/systemd/user/vaultsync-bridge.service';

  String get _home => Platform.environment['HOME'] ?? '/home/deck';
  String get _serviceFilePath => '$_home/$_serviceFile';

  String get _bridgeScript {
    // In production the script is next to the binary; in debug mode fall back
    // to the linux/ source directory.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final prod = '$exeDir/vaultsync_bridge.py';
    if (File(prod).existsSync()) return prod;
    // dev fallback — find linux/ relative to project root
    final dev = '$exeDir/../../../linux/vaultsync_bridge.py';
    final devNorm = File(dev).absolute.path;
    if (File(devNorm).existsSync()) return devNorm;
    return prod; // return production path even if missing — installer will report error
  }

  @override
  Future<DeckyBridgeStatus> build() => _checkStatus();

  Future<DeckyBridgeStatus> _checkStatus() async {
    if (!Platform.isLinux) return DeckyBridgeStatus.unknown;
    if (!File(_serviceFilePath).existsSync()) {
      return DeckyBridgeStatus.notInstalled;
    }
    final result = await Process.run(
      'systemctl', ['--user', 'is-active', _serviceName],
    );
    return result.stdout.toString().trim() == 'active'
        ? DeckyBridgeStatus.running
        : DeckyBridgeStatus.stopped;
  }

  Future<String?> install() async {
    state = const AsyncData(DeckyBridgeStatus.installing);
    try {
      // 1. Verify python3
      final py = await Process.run('which', ['python3']);
      if (py.exitCode != 0) {
        return 'python3 not found. Install it via your package manager.';
      }
      final python3 = py.stdout.toString().trim();

      // 2. Verify bridge script exists
      if (!File(_bridgeScript).existsSync()) {
        return 'Bridge script not found at $_bridgeScript';
      }

      // 3. Install Python dependencies
      final deps = ['aiohttp', 'requests', 'cryptography'];
      final pipResult = await Process.run(
        python3, ['-m', 'pip', 'install', '--quiet', ...deps],
      );
      if (pipResult.exitCode != 0) {
        developer.log(
            'DECKY: pip install failed:\n${pipResult.stderr}',
            name: 'VaultSync',
            level: 900);
        return 'pip install failed: ${pipResult.stderr.toString().trim().split('\n').last}';
      }

      // 4. Write systemd unit
      final serviceDir = Directory('$_home/.config/systemd/user');
      await serviceDir.create(recursive: true);
      await File(_serviceFilePath).writeAsString(_buildServiceUnit(python3));

      // 5. Enable and start
      await Process.run('systemctl', ['--user', 'daemon-reload']);
      await Process.run(
          'systemctl', ['--user', 'enable', '--now', _serviceName]);

      await Future.delayed(const Duration(seconds: 2));
      state = AsyncData(await _checkStatus());
      if (state.value != DeckyBridgeStatus.running) {
        return 'Service installed but failed to start. Check: journalctl --user -u $_serviceName';
      }
      return null; // success
    } catch (e) {
      state = const AsyncData(DeckyBridgeStatus.notInstalled);
      return e.toString();
    }
  }

  Future<void> start() async {
    await Process.run('systemctl', ['--user', 'start', _serviceName]);
    await Future.delayed(const Duration(seconds: 1));
    state = AsyncData(await _checkStatus());
  }

  Future<void> stop() async {
    await Process.run('systemctl', ['--user', 'stop', _serviceName]);
    state = AsyncData(await _checkStatus());
  }

  Future<String?> uninstall() async {
    await Process.run('systemctl', ['--user', 'disable', '--now', _serviceName]);
    try {
      await File(_serviceFilePath).delete();
    } catch (_) {}
    await Process.run('systemctl', ['--user', 'daemon-reload']);
    state = const AsyncData(DeckyBridgeStatus.notInstalled);
    return null;
  }

  Future<void> refresh() async {
    state = AsyncData(await _checkStatus());
  }

  String _buildServiceUnit(String python3Path) => '''
[Unit]
Description=VaultSync Decky Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$python3Path $_bridgeScript
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
''';
}
