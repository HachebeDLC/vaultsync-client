import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:system_tray/system_tray.dart';
import 'desktop_background_sync_service.dart';

final desktopTrayServiceProvider = Provider<DesktopTrayService>((ref) {
  return DesktopTrayService(ref);
});

class DesktopTrayService {
  final Ref _ref;
  SystemTray? _systemTray;
  final Menu _menu = Menu();

  DesktopTrayService(this._ref);

  /// Check whether a StatusNotifier tray host is available on the session bus.
  /// If not, calling initSystemTray will segfault the native plugin.
  Future<bool> _hasTrayHost() async {
    if (Platform.isWindows) return true;
    if (!Platform.isLinux) return false;
    try {
      final result = await Process.run('dbus-send', [
        '--session',
        '--dest=org.freedesktop.DBus',
        '--type=method_call',
        '--print-reply',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus.NameHasOwner',
        'string:org.kde.StatusNotifierWatcher',
      ]);
      return result.stdout.toString().contains('boolean true');
    } catch (_) {
      return false;
    }
  }

  bool get _isInsideFlatpak => Platform.isLinux && File('/.flatpak-info').existsSync();

  Future<void> initTray() async {
    if (!Platform.isWindows && !Platform.isLinux) return;

    // The system_tray native plugin segfaults inside Flatpak sandboxes
    // (missing cursor theme / icon resources). Skip it — on Steam Deck
    // the Decky plugin bridge is the primary interface.
    if (_isInsideFlatpak) {
      developer.log('TRAY: Running inside Flatpak, skipping system tray.',
          name: 'VaultSync', level: 800);
      return;
    }

    if (!await _hasTrayHost()) {
      developer.log('TRAY: No StatusNotifierWatcher found, skipping system tray.',
          name: 'VaultSync', level: 800);
      return;
    }

    try {
      _systemTray = SystemTray();
      String path = Platform.isWindows
          ? 'assets/vaultsync_icon.ico'
          : 'assets/vaultsync_icon.png';

      await _systemTray!.initSystemTray(
        title: "VaultSync",
        iconPath: path,
      );

      await _menu.buildFrom([
        MenuItemLabel(label: 'Show App', onClicked: (menuItem) => _systemTray!.popUpContextMenu()),
        MenuSeparator(),
        MenuItemLabel(
          label: 'Sync All',
          onClicked: (menuItem) {
            developer.log('TRAY: Triggering manual sync...', name: 'VaultSync', level: 800);
            _ref.read(desktopBackgroundSyncServiceProvider).sync();
          }
        ),
        MenuSeparator(),
        MenuItemLabel(label: 'Exit', onClicked: (menuItem) => exit(0)),
      ]);

      await _systemTray!.setContextMenu(_menu);

      _systemTray!.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          _systemTray!.popUpContextMenu();
        } else if (eventName == kSystemTrayEventRightClick) {
          _systemTray!.popUpContextMenu();
        }
      });
    } catch (e) {
      developer.log('TRAY: System tray init failed, skipping.', name: 'VaultSync', level: 800, error: e);
    }
  }
}
