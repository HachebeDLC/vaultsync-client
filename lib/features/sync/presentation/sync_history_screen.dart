import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../domain/sync_log_provider.dart';

class SyncHistoryScreen extends ConsumerWidget {
  const SyncHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(syncLogProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => ref.read(syncLogProvider.notifier).clearLogs(),
            tooltip: 'Clear History',
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No sync history found.', style: TextStyle(color: Colors.grey)),
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
                    ],
                  ),
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
}
