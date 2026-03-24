import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/domain/notification_provider.dart';
import 'package:vaultsync_client/features/sync/domain/notification_models.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';
import 'dart:io';

void main() {
  late NotificationLogNotifier notifier;

  setUp(() {
    notifier = NotificationLogNotifier();
  });

  group('NotificationLogNotifier', () {
    test('should increment unreadActionableCount only for actionable errors', () {
      expect(notifier.unreadActionableCount, 0);

      // 1. Add non-actionable error
      notifier.addNotification(
        title: 'Transient Error',
        message: 'Something went wrong but we retried',
        type: NotificationType.error,
        action: SyncAction.none,
      );
      expect(notifier.unreadActionableCount, 0); // Still 0

      // 2. Add actionable error
      notifier.addNotification(
        title: 'Auth Error',
        message: 'Login required',
        type: NotificationType.error,
        action: SyncAction.login,
      );
      expect(notifier.unreadActionableCount, 1);

      // 3. Add another actionable error
      notifier.addNotification(
        title: 'Permission Error',
        message: 'Folder access needed',
        type: NotificationType.error,
        action: SyncAction.reselectFolder,
      );
      expect(notifier.unreadActionableCount, 2);
    });

    test('markAllAsRead should reset unreadActionableCount', () {
      notifier.addNotification(
        title: 'Error',
        message: 'msg',
        type: NotificationType.error,
        action: SyncAction.login,
      );
      expect(notifier.unreadActionableCount, 1);

      notifier.markAllAsRead();
      expect(notifier.unreadActionableCount, 0);
    });

    test('addError should automatically map to actionable if needed', () {
      // Simulate a SocketException which maps to SyncAction.checkNetwork
      notifier.addError(const SocketException('No internet'));
      
      expect(notifier.state.first.action, SyncAction.checkNetwork);
      expect(notifier.unreadActionableCount, 1);
    });
  });
}
