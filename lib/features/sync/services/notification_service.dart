import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/launcher_icon');
    await _notifications.initialize(const InitializationSettings(android: android));
    _initialized = true;
  }

  Future<void> showSyncStatus(String title, String body) async {
    await init();
    const android = AndroidNotificationDetails(
      'sync_status', 'Sync Status',
      channelDescription: 'Shows progress of background save sync',
      importance: Importance.low, priority: Priority.low, showWhen: false, onlyAlertOnce: true,
    );
    await _notifications.show(999, title, body, const NotificationDetails(android: android));
  }

  Future<void> clearSyncStatus() async {
    await _notifications.cancel(999);
  }
}
