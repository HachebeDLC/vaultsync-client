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
                  title: Text(log.systemId.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(log.status),
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
