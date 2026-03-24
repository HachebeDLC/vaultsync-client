import '../../../core/errors/error_mapper.dart';

enum NotificationType { error, warning, info }

class NotificationLog {
  final String id;
  final String title;
  final String message;
  final NotificationType type;
  final DateTime timestamp;
  final bool isRead;
  final String? systemId;
  final SyncAction action;
  final dynamic originalError;

  NotificationLog({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.timestamp,
    this.isRead = false,
    this.action = SyncAction.none,
    this.systemId,
    this.originalError,
  });

  bool get isActionable => action != SyncAction.none;

  NotificationLog copyWith({bool? isRead}) {
    return NotificationLog(
      id: id,
      title: title,
      message: message,
      type: type,
      timestamp: timestamp,
      isRead: isRead ?? this.isRead,
      action: action,
      systemId: systemId,
      originalError: originalError,
    );
  }
}
