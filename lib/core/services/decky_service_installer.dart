import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'decky_bridge_service.dart';

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

  /// Returns the real host home directory, bypassing the Flatpak sandbox home.
  Future<String> _getHostHome() async {
    if (!_isInsideFlatpak) return _home;
    try {
      final result = await Process.run('flatpak-spawn', ['--host', 'sh', '-c', 'echo \$HOME']);
      if (result.exitCode == 0) return result.stdout.toString().trim();
    } catch (_) {}
    return '/home/deck'; // Steam Deck default fallback
  }

  // When the app is running inside a Flatpak sandbox, systemctl and python3
  // must be invoked on the host via flatpak-spawn --host.
  bool get _isInsideFlatpak => File('/.flatpak-info').existsSync();

  Future<ProcessResult> _run(String exe, List<String> args) =>
      _isInsideFlatpak
          ? Process.run('flatpak-spawn', ['--host', exe, ...args])
          : Process.run(exe, args);

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

  // When inside a Flatpak sandbox /app/... paths are not visible to systemd
  // on the host. We copy the script to $HOME/.local/share/vaultsync/ which is
  // accessible from the host (granted via --filesystem=home in the manifest).
  String get _hostBridgeScript => _isInsideFlatpak
      ? '$_home/.local/share/vaultsync/vaultsync_bridge.py'
      : _bridgeScript;

  @override
  Future<DeckyBridgeStatus> build() => _checkStatus();

  Future<DeckyBridgeStatus> _checkStatus() async {
    if (!Platform.isLinux) return DeckyBridgeStatus.unknown;
    final serviceFile = File(_serviceFilePath);
    if (!serviceFile.existsSync()) return DeckyBridgeStatus.notInstalled;

    // If the service file doesn't reference the expected bridge script path it
    // was written by an old installer (pointing at a now-deleted bundle).
    // Treat it as not-installed so the user is prompted to reinstall cleanly.
    final serviceContent = serviceFile.readAsStringSync();
    if (!serviceContent.contains(_hostBridgeScript)) {
      developer.log('DECKY INSTALLER: stale service file detected (wrong ExecStart path)', name: 'VaultSync', level: 900);
      return DeckyBridgeStatus.notInstalled;
    }

    final result = await _run(
      'systemctl', ['--user', 'is-active', _serviceName],
    );
    return result.stdout.toString().trim() == 'active'
        ? DeckyBridgeStatus.running
        : DeckyBridgeStatus.stopped;
  }

  String get _venvDir => '$_home/.local/share/vaultsync/venv';
  String get _venvPython => '$_venvDir/bin/python3';

  /// Removes the autostart .desktop created by the old install_autostart.sh
  /// script if it points to a non-existent binary (i.e. a deleted bundle).
  void _removeStaleAutostart() {
    final desktopFile = File('$_home/.config/autostart/vaultsync.desktop');
    if (!desktopFile.existsSync()) return;
    try {
      final content = desktopFile.readAsStringSync();
      final execMatch = RegExp(r'^Exec=(.+)$', multiLine: true).firstMatch(content);
      if (execMatch != null) {
        final execBin = execMatch.group(1)!.split(' ').first;
        if (!File(execBin).existsSync()) {
          desktopFile.deleteSync();
          developer.log('DECKY INSTALLER: removed stale autostart desktop ($execBin no longer exists)', name: 'VaultSync', level: 800);
        }
      }
    } catch (e) {
      developer.log('DECKY INSTALLER: could not check autostart desktop: $e', name: 'VaultSync', level: 900);
    }
  }

  Future<String?> install() async {
    state = const AsyncData(DeckyBridgeStatus.installing);
    try {
      // 1. Find python3 — inside Flatpak, flatpak-spawn --host has a
      //    minimal PATH, so check known locations directly.
      String python3 = '';
      if (_isInsideFlatpak) {
        for (final p in ['/usr/bin/python3', '/usr/bin/python']) {
          final check = await _run(p, ['--version']);
          if (check.exitCode == 0) {
            python3 = p;
            break;
          }
        }
      } else {
        final py = await Process.run('which', ['python3']);
        if (py.exitCode == 0) python3 = py.stdout.toString().trim();
      }
      if (python3.isEmpty) {
        return 'python3 not found. Install it via your package manager.';
      }

      // 2. Verify bridge script exists
      if (!File(_bridgeScript).existsSync()) {
        return 'Bridge script not found at $_bridgeScript';
      }

      // 2b. If inside Flatpak, copy bridge script to a host-accessible path
      //     so the systemd unit (which runs on the host) can reference it.
      if (_isInsideFlatpak) {
        final hostScript = _hostBridgeScript;
        await Directory(File(hostScript).parent.path).create(recursive: true);
        await File(_bridgeScript).copy(hostScript);
        await Process.run('chmod', ['+x', hostScript]);
      }

      // 3. Create venv (avoids pip3-not-found and externally-managed-env errors
      //    on Steam Deck / Arch and modern Debian/Ubuntu systems)
      final venvResult = await _run(python3, ['-m', 'venv', _venvDir]);
      if (venvResult.exitCode != 0) {
        developer.log('DECKY: venv creation failed:\n${venvResult.stderr}',
            name: 'VaultSync', level: 900);
        return 'Failed to create Python venv: ${venvResult.stderr.toString().trim().split('\n').last}';
      }

      // 4. Install dependencies into the venv
      final deps = ['aiohttp', 'requests', 'cryptography'];
      final pipResult = await _run(
        _venvPython, ['-m', 'pip', 'install', '--quiet', ...deps],
      );
      if (pipResult.exitCode != 0) {
        developer.log(
            'DECKY: pip install failed:\n${pipResult.stderr}',
            name: 'VaultSync',
            level: 900);
        return 'pip install failed: ${pipResult.stderr.toString().trim().split('\n').last}';
      }

      // 5. Write systemd unit
      final serviceDir = Directory('$_home/.config/systemd/user');
      await serviceDir.create(recursive: true);
      await File(_serviceFilePath).writeAsString(_buildServiceUnit(_venvPython));

      // 5b. Remove the legacy autostart .desktop left by install_autostart.sh.
      //     The Flatpak app registers itself via the system app list; a stale
      //     autostart entry pointing at a deleted bundle binary just causes errors.
      _removeStaleAutostart();

      // 6. Stop the in-process Dart bridge so the systemd service can bind port 5437.
      await ref.read(deckyBridgeServiceProvider).stop();

      // 7. Enable and start
      await _run('systemctl', ['--user', 'daemon-reload']);
      await _run('systemctl', ['--user', 'enable', '--now', _serviceName]);

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
    // Free the port before starting the systemd service.
    await ref.read(deckyBridgeServiceProvider).stop();
    await _run('systemctl', ['--user', 'start', _serviceName]);
    await Future.delayed(const Duration(seconds: 1));
    state = AsyncData(await _checkStatus());
  }

  Future<void> stop() async {
    await _run('systemctl', ['--user', 'stop', _serviceName]);
    state = AsyncData(await _checkStatus());
  }

  Future<String?> uninstall() async {
    await _run('systemctl', ['--user', 'disable', '--now', _serviceName]);
    try {
      await File(_serviceFilePath).delete();
    } catch (_) {}
    await _run('systemctl', ['--user', 'daemon-reload']);
    _removeStaleAutostart();
    state = const AsyncData(DeckyBridgeStatus.notInstalled);
    // Restore the in-process Dart bridge now that the port is free.
    await ref.read(deckyBridgeServiceProvider).start();
    return null;
  }

  Future<void> refresh() async {
    state = AsyncData(await _checkStatus());
  }

  Future<String?> deployPlugin() async {
    if (!Platform.isLinux) return 'Deployment only supported on Linux';
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      var pluginSrc = _isInsideFlatpak
          ? '/app/lib/vaultsync/decky_plugin'
          : '$exeDir/decky_plugin';

      if (!Directory(pluginSrc).existsSync()) {
        final devPath = '$exeDir/../../../vaultsync_decky';
        if (!Directory(devPath).existsSync()) {
          return 'Plugin source not found at $pluginSrc';
        }
        pluginSrc = devPath;
      }

      final destDir = '$_home/homebrew/plugins/VaultSync';

      // 1. Wipe any previous install before copying. Decky's plugin dir is
      //    owned by the running plugin_loader user, and a half-written
      //    previous deploy produces "plugin.json: File exists" on the next
      //    cp/tar overlay because type/ownership can't be replaced in place.
      await _run('rm', ['-rf', destDir]);
      await _run('mkdir', ['-p', destDir]);

      // 2. Copy files (recursive)
      // Note: cp -r inside flatpak-spawn needs careful path handling.
      // Since we have home filesystem access, we can copy from /app/lib to ~/homebrew
      if (_isInsideFlatpak) {
        // Use a shell script on the host to do the heavy lifting of copying from the container
        // Actually, Flatpak can't easily see its own /app from the host shell.
        // We'll use the 'tar' trick to stream files out.
        final tarCmd = 'tar -C $pluginSrc -cf - . | flatpak-spawn --host tar -C $destDir -xf -';
        final result = await Process.run('sh', ['-c', tarCmd]);
        if (result.exitCode != 0) return 'Failed to deploy plugin: ${result.stderr}';
      } else {
        await Process.run('cp', ['-r', '$pluginSrc/.', destDir]);
      }

      // 3. Set permissions
      await _run('chmod', ['-R', '755', destDir]);

      return null; // Success
    } catch (e) {
      return e.toString();
    }
  }

  String _buildServiceUnit(String python3Path) => '''
[Unit]
Description=VaultSync Decky Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$python3Path $_hostBridgeScript
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
''';
}
