import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:system_tray/system_tray.dart';
import 'desktop_background_sync_service.dart';

final desktopTrayServiceProvider = Provider<DesktopTrayService>((ref) {
  return DesktopTrayService(ref);
});

class DesktopTrayService {
  final Ref _ref;
  final SystemTray _systemTray = SystemTray();
  final Menu _menu = Menu();

  DesktopTrayService(this._ref);

  Future<void> initTray() async {
    if (!Platform.isWindows && !Platform.isLinux) return;

    String path = Platform.isWindows
        ? 'assets/vaultsync_icon.ico'
        : 'assets/vaultsync_icon.png';

    await _systemTray.initSystemTray(
      title: "VaultSync",
      iconPath: path,
    );

    await _menu.buildFrom([
      MenuItemLabel(label: 'Show App', onClicked: (menuItem) => _systemTray.popUpContextMenu()),
      MenuSeparator(),
      MenuItemLabel(
        label: 'Sync All', 
        onClicked: (menuItem) {
          print('🚀 TRAY: Triggering manual sync...');
          _ref.read(desktopBackgroundSyncServiceProvider).sync();
        }
      ),
      MenuSeparator(),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) => exit(0)),
    ]);

    await _systemTray.setContextMenu(_menu);

    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        _systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
  }
}
