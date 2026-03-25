import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  final _notifications = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(const InitializationSettings(android: android));
  }

  Future<void> showSyncStatus(String title, String body) async {
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
