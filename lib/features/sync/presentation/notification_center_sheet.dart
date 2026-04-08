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
import '../../../l10n/generated/app_localizations.dart';

class NotificationCenterSheet extends ConsumerWidget {
  const NotificationCenterSheet({super.key});

  void _showReportPreview(BuildContext context, WidgetRef ref) async {
    final service = ref.read(diagnosticReportServiceProvider);
    final report = await service.generateMarkdownReport();
    final l10n = AppLocalizations.of(context)!;

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
        title: Text(l10n.diagnosticReportTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.diagnosticReportDescription,
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Text(
                    report,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: colorScheme.onSurface,
                    ),
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
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.reportCopied)));
            },
            child: Text(l10n.copyButton),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              service.reportToGitHub();
            },
            child: Text(l10n.reportToGithubButton),
          ),
        ],
      );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationLogProvider);
    final notifier = ref.read(notificationLogProvider.notifier);
    final l10n = AppLocalizations.of(context)!;

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHeader(context, ref, notifier, notifications.isEmpty, l10n),
          const Divider(height: 1),
          Expanded(
            child: notifications.isEmpty
                ? _buildEmptyState(l10n)
                : _buildList(context, ref, notifications, notifier, l10n),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, NotificationLogNotifier notifier, bool isEmpty, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Text(l10n.sessionEventsTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _showReportPreview(context, ref),
            icon: const Icon(Icons.bug_report_outlined, size: 18),
            label: Text(l10n.reportButton),
          ),
          if (!isEmpty)
            TextButton(
              onPressed: () => notifier.clearAll(),
              child: Text(l10n.clearButton),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.notifications_none, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(l10n.noEventsInSession, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, List<NotificationLog> logs, NotificationLogNotifier notifier, AppLocalizations l10n) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: logs.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final log = logs[index];
        return _buildNotificationItem(context, ref, log, notifier, l10n);
      },
    );
  }

  Widget _buildNotificationItem(BuildContext context, WidgetRef ref, NotificationLog log, NotificationLogNotifier notifier, AppLocalizations l10n) {
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
                    child: Text(_getActionLabel(log.action, l10n)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getActionLabel(SyncAction action, AppLocalizations l10n) {
    switch (action) {
      case SyncAction.login: return l10n.actionLogin;
      case SyncAction.openShizuku: return l10n.actionFixBridge;
      case SyncAction.reselectFolder: return l10n.actionSettings;
      case SyncAction.checkNetwork: return l10n.actionRetry;
      default: return l10n.actionFix;
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
