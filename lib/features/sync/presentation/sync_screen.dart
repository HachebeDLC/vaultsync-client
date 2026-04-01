import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/sync_provider.dart';

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final offlineCount = ref.watch(pendingOfflineJobsCountProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Synchronization')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (syncState.isSyncing)
              const CircularProgressIndicator()
            else
              const Icon(Icons.cloud_sync, size: 64, color: Colors.blue),
            const SizedBox(height: 20),
            Text(syncState.status, textAlign: TextAlign.center),
            if (offlineCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '$offlineCount pending offline changes',
                  style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (syncState.isSyncing)
              LinearProgressIndicator(value: syncState.progress)
            else
              ElevatedButton(
                onPressed: () {
                  ref.read(syncProvider.notifier).sync();
                },
                child: const Text('Start Sync'),
              ),
          ],
        ),
      ),
    );
  }
}
