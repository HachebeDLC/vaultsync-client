import 'dart:io';
import 'package:flutter/material.dart';
import 'package:system_tray/system_tray.dart';

class DesktopTrayService {
  final SystemTray _systemTray = SystemTray();
  final Menu _menu = Menu();

  Future<void> initTray() async {
    if (!Platform.isWindows && !Platform.isLinux) return;

    String path = Platform.isWindows
        ? 'assets/vaultsync_icon.png'
        : 'assets/vaultsync_icon.png';

    // We might need to convert png to ico for windows in a real build, 
    // but system_tray supports png on windows too.

    await _systemTray.initTray(
      title: "VaultSync",
      iconPath: path,
    );

    await _menu.buildFrom([
      MenuItemLabel(label: 'Show App', onClicked: (menuItem) => _systemTray.popUpContextMenu()),
      MenuSeparator(),
      MenuItemLabel(label: 'Sync All', onClicked: (menuItem) => print('Syncing from tray...')),
      MenuSeparator(),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) => exit(0)),
    ]);

    await _systemTray.setContextMenu(_menu);

    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        Platform.isWindows ? _systemTray.popUpContextMenu() : _systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
  }
}
