import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_models.dart';
import '../../../core/errors/error_mapper.dart';
import 'package:uuid/uuid.dart';

final notificationLogProvider = StateNotifierProvider<NotificationLogNotifier, List<NotificationLog>>((ref) {
  return NotificationLogNotifier();
});

class NotificationLogNotifier extends StateNotifier<List<NotificationLog>> {
  NotificationLogNotifier() : super([]);

  final _uuid = const Uuid();

  int get unreadActionableCount => state.where((n) => !n.isRead && n.isActionable).length;

  void addNotification({
    required String title,
    required String message,
    required NotificationType type,
    String? systemId,
    SyncAction action = SyncAction.none,
    dynamic originalError,
  }) {
    final notification = NotificationLog(
      id: _uuid.v4(),
      title: title,
      message: message,
      type: type,
      timestamp: DateTime.now(),
      systemId: systemId,
      action: action,
      originalError: originalError,
    );
    
    // Memory-only: keep only last 100 notifications
    state = [notification, ...state].take(100).toList();
  }

  void addError(dynamic error, {String? systemId}) {
    final userError = ErrorMapper.map(error);
    addNotification(
      title: userError.title,
      message: userError.message,
      type: NotificationType.error,
      systemId: systemId,
      action: userError.action,
      originalError: error,
    );
  }

  void markAsRead(String id) {
    state = [
      for (final n in state)
        if (n.id == id) n.copyWith(isRead: true) else n,
    ];
  }

  void markAllAsRead() {
    state = [
      for (final n in state) n.copyWith(isRead: true),
    ];
  }

  void clearAll() {
    state = [];
  }
}
