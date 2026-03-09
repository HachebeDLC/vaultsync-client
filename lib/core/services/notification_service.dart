import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/launcher_icon');
    const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open VaultSync');
    const initSettings = InitializationSettings(
      android: androidSettings,
      linux: linuxSettings,
    );
    await _notifications.initialize(initSettings);
  }

  static Future<void> showSyncNotification({required String title, required String body}) async {
    const androidDetails = AndroidNotificationDetails(
      'sync_channel',
      'Synchronization',
      channelDescription: 'Notifications for background save syncing',
      importance: Importance.low,
      priority: Priority.low,
      showWhen: true,
    );
    const linuxDetails = LinuxNotificationDetails();
    const notificationDetails = NotificationDetails(
      android: androidDetails,
      linux: linuxDetails,
    );
    await _notifications.show(0, title, body, notificationDetails);
  }

  static Future<void> clearAll() async {
    await _notifications.cancelAll();
  }
}
