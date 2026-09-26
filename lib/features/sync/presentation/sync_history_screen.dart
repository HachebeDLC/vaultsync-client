import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../domain/sync_log_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

class SyncHistoryScreen extends ConsumerWidget {
  const SyncHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(syncLogProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncHistoryTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => ref.read(syncLogProvider.notifier).clearLogs(),
            tooltip: l10n.clearHistoryTooltip,
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.history, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(l10n.noSyncHistoryFound, style: const TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: logs.length,
              separatorBuilder: (context, index) => const Divider(),
              itemBuilder: (context, index) {
                final log = logs[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: log.isError ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                    child: Icon(
                      log.isError ? Icons.error_outline : Icons.check_circle_outline,
                      color: log.isError ? Colors.red : Colors.green,
                    ),
                  ),
                  title: Row(
                    children: [
                      Text(log.systemId.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      if (log.actionLabel != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.blue.withOpacity(0.5)),
                          ),
                          child: Text(
                            log.actionLabel!,
                            style: const TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (log.errorTitle != null)
                        Text(
                          log.errorTitle!,
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w500, fontSize: 13),
                        ),
                      Text(log.status, style: TextStyle(fontSize: 12, color: log.isError ? Colors.black87 : Colors.grey[600])),
                      if (log.detail != null && log.detail!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: InkWell(
                            onTap: () => _showDetailDialog(context, log),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    log.detail!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.unfold_more, size: 14, color: Colors.grey[500]),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  isThreeLine: log.detail != null && log.detail!.isNotEmpty,
                  trailing: Text(
                    DateFormat('HH:mm\nMMM d').format(log.timestamp),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }

  /// Full, unabridged technical detail for a history entry (the exception's
  /// real type + message, already redacted/truncated by `buildErrorDetail`
  /// when the entry was written) in a scrollable, selectable dialog —
  /// reached by tapping the truncated secondary line in the list. Mirrors
  /// `DashboardScreen._showErrorDetails`.
  void _showDetailDialog(BuildContext context, SyncLog log) {
    final fullText = log.errorTitle != null
        ? '${log.errorTitle}\n\n${log.status}\n\nCause: ${log.detail}'
        : '${log.status}\n\nCause: ${log.detail}';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Error Details'),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: SingleChildScrollView(
                child: SelectableText(fullText, style: const TextStyle(fontSize: 13)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: fullText)),
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
