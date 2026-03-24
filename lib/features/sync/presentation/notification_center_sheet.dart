import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../domain/notification_models.dart';
import '../domain/notification_provider.dart';
import '../../../core/errors/error_mapper.dart';
import '../services/shizuku_service.dart';
import '../services/diagnostic_report_service.dart';

class NotificationCenterSheet extends ConsumerWidget {
  const NotificationCenterSheet({super.key});

  void _showReportPreview(BuildContext context, WidgetRef ref) async {
    final service = ref.read(diagnosticReportServiceProvider);
    final report = await service.generateMarkdownReport();

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostic Report'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'The following report will be submitted to GitHub. Sensitive information like emails and full paths have been redacted.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Text(
                    report,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report copied to clipboard')));
            },
            child: const Text('COPY'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              service.reportToGitHub();
            },
            child: const Text('REPORT TO GITHUB'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationLogProvider);
    final notifier = ref.read(notificationLogProvider.notifier);

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHeader(context, ref, notifier, notifications.isEmpty),
          const Divider(height: 1),
          Expanded(
            child: notifications.isEmpty
                ? _buildEmptyState()
                : _buildList(context, ref, notifications, notifier),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, NotificationLogNotifier notifier, bool isEmpty) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          const Text('Session Events', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _showReportPreview(context, ref),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: const Text('Report'),
          ),
          if (!isEmpty)
            TextButton(
              onPressed: () => notifier.clearAll(),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notifications_none, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('No events in this session', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<NotificationLog> logs, NotificationLogNotifier notifier) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: logs.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final log = logs[index];
        return _buildNotificationItem(context, ref, log, notifier);
      },
    );
  }

  Widget _buildNotificationItem(BuildContext context, WidgetRef ref, NotificationLog log, NotificationLogNotifier notifier) {
    final color = log.type == NotificationType.error ? Colors.red : Colors.blue;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withOpacity(0.2)),
      ),
      color: log.isRead ? Colors.grey.withOpacity(0.05) : color.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  log.type == NotificationType.error ? Icons.error_outline : Icons.info_outline,
                  color: color,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    log.title,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color),
                  ),
                ),
                Text(
                  DateFormat('HH:mm').format(log.timestamp),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(log.message, style: const TextStyle(fontSize: 13)),
            if (log.isActionable) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      notifier.markAsRead(log.id);
                      _handleAction(context, ref, log.action);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: color,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      backgroundColor: color.withOpacity(0.1),
                    ),
                    child: Text(_getActionLabel(log.action)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getActionLabel(SyncAction action) {
    switch (action) {
      case SyncAction.login: return 'LOGIN';
      case SyncAction.openShizuku: return 'FIX BRIDGE';
      case SyncAction.reselectFolder: return 'SETTINGS';
      case SyncAction.checkNetwork: return 'RETRY';
      default: return 'FIX';
    }
  }

  void _handleAction(BuildContext context, WidgetRef ref, SyncAction action) {
    Navigator.pop(context); // Close sheet
    switch (action) {
      case SyncAction.login:
        context.push('/auth');
        break;
      case SyncAction.reselectFolder:
        context.push('/settings');
        break;
      case SyncAction.openShizuku:
        ref.read(shizukuServiceProvider).openApp();
        break;
      default:
        break;
    }
  }
}
