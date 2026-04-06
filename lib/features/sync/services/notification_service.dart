import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    // flutter_local_notifications_linux crashes when initialized without
    // LinuxInitializationSettings. Notifications are not used on Linux/desktop.
    if (!Platform.isAndroid && !Platform.isIOS) {
      _initialized = true;
      return;
    }
    const android = AndroidInitializationSettings('@mipmap/launcher_icon');
    await _notifications.initialize(const InitializationSettings(android: android));
    _initialized = true;
  }

  Future<void> showSyncStatus(String title, String body) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await init();
    const android = AndroidNotificationDetails(
      'sync_status', 'Sync Status',
      channelDescription: 'Shows progress of background save sync',
      importance: Importance.low, priority: Priority.low, showWhen: false, onlyAlertOnce: true,
    );
    await _notifications.show(999, title, body, const NotificationDetails(android: android));
  }

  Future<void> clearSyncStatus() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _notifications.cancel(999);
  }
}
