import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/sync_provider.dart';
import 'package:intl/intl.dart';

class ConflictScreen extends ConsumerWidget {
  const ConflictScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final conflicts = syncState.conflicts;

    return Scaffold(
      appBar: AppBar(title: const Text('Resolve Conflicts')),
      body: conflicts.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: conflicts.length,
              itemBuilder: (context, index) {
                final conflict = conflicts[index];
                return _buildConflictCard(context, ref, conflict);
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 64, color: Colors.green.shade200),
          const SizedBox(height: 16),
          const Text('All files are in sync!', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildConflictCard(BuildContext context, WidgetRef ref, Map<String, dynamic> conflict) {
    final String path = conflict['path'] ?? 'Unknown';
    final String fileName = path.split('/').last.split('.sync-conflict-').first;
    
    // Cloud Side Metadata
    final String cloudDevice = conflict['device_name'] ?? 'Remote Device';
    DateTime cloudDate = DateTime.now();
    if (path.contains('.sync-conflict-')) {
       try {
         final datePart = path.split('.sync-conflict-')[1].split('-')[0];
         cloudDate = DateTime.parse(datePart); // Simple parse for now
       } catch (e) {
         developer.log('UI: Conflict date parse failed', name: 'VaultSync', level: 900, error: e);
       }
    }

    // Local Side Metadata (Mocked for now until repo passes actual localInfo)
    const String localDevice = 'Thor (This Device)';
    final DateTime localDate = DateTime.now().subtract(const Duration(hours: 1));

    final bool isCloudNewer = cloudDate.isAfter(localDate);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.orange.withOpacity(0.1),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildVersionPanel(
                  context, 
                  title: 'LOCAL VERSION',
                  device: localDevice,
                  date: localDate,
                  icon: Icons.smartphone,
                  isNewer: !isCloudNewer,
                  onSelect: () => _resolve(context, ref, conflict, true),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.compare_arrows, color: Colors.grey),
                ),
                _buildVersionPanel(
                  context, 
                  title: 'CLOUD VERSION',
                  device: cloudDevice,
                  date: cloudDate,
                  icon: Icons.cloud_outlined,
                  isNewer: isCloudNewer,
                  onSelect: () => _resolve(context, ref, conflict, false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVersionPanel(
    BuildContext context, {
    required String title,
    required String device,
    required DateTime date,
    required IconData icon,
    required bool isNewer,
    required VoidCallback onSelect,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: isNewer ? Colors.green : Colors.grey.shade300, width: isNewer ? 2 : 1),
              borderRadius: BorderRadius.circular(8),
              color: isNewer ? Colors.green.withOpacity(0.05) : null,
            ),
            child: Column(
              children: [
                if (isNewer)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(4)),
                    child: const Text('NEWER', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                  ),
                Icon(icon, color: isNewer ? Colors.green : Colors.grey),
                const SizedBox(height: 8),
                Text(device, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text(DateFormat('MMM d, HH:mm').format(date), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onSelect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isNewer ? Colors.green : Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)
                    ),
                    child: const Text('KEEP THIS'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref, Map<String, dynamic> conflict, bool keepLocal) async {
    final fileName = (conflict['path'] as String).split('/').last.split('.sync-conflict-').first;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Resolving $fileName...'), duration: const Duration(seconds: 1)),
    );
    
    try {
      await ref.read(syncProvider.notifier).resolveConflict(conflict, keepLocal);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Resolved: $fileName kept ${keepLocal ? 'Local' : 'Cloud'} version.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error resolving conflict: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
