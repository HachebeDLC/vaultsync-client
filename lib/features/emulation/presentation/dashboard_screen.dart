import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../sync/domain/sync_provider.dart';
import '../../sync/services/system_path_service.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  String _formatSafPath(String path) {
    if (path.startsWith('content://')) {
      try {
        final decoded = Uri.decodeComponent(path);
        if (decoded.contains('primary:')) {
          return '/storage/emulated/0/${decoded.split('primary:').last}';
        } else if (decoded.contains(':')) {
          final parts = decoded.split(':');
          return 'SD Card/${parts.last.split('/document/').last}';
        }
        return decoded.split('/').last;
      } catch (_) {}
    }
    return path;
  }

  IconData _getSystemIcon(String systemId) {
    final id = systemId.toLowerCase();
    if (id.contains('gba') || id.contains('gbc') || id.contains('gb')) return Icons.gamepad;
    if (id.contains('ps1') || id.contains('ps2') || id.contains('psx') || id.contains('psp')) return Icons.sports_esports;
    if (id.contains('switch') || id.contains('ns')) return Icons.switch_left;
    if (id.contains('ds') || id.contains('3ds')) return Icons.developer_board;
    if (id.contains('n64') || id.contains('gc') || id.contains('wii')) return Icons.videogame_asset;
    if (id.contains('retroarch')) return Icons.settings_input_component;
    return Icons.folder;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final pathsAsync = ref.watch(systemPathsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('VaultSync Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Scan Library',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/library-setup'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: pathsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
        data: (paths) {
          print('🎨 RENDER: Dashboard building with ${paths.length} systems');
          
          if (paths.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('No systems configured yet.'),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.search),
                    label: const Text('Scan Library'),
                    onPressed: () => context.push('/library-setup'),
                  ),
                ],
              ),
            );
          }

          return LayoutBuilder(builder: (context, constraints) {
            final isWide = constraints.maxWidth > 600;
            
            final systemsListView = ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: paths.length,
              itemBuilder: (context, index) {
                final entry = paths.entries.elementAt(index);
                final systemId = entry.key;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue.withOpacity(0.1),
                      child: Icon(_getSystemIcon(systemId), color: Colors.blue),
                    ),
                    title: Text(systemId.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_formatSafPath(entry.value), maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    onTap: () => context.push('/system-detail/$systemId'),
                  ),
                );
              },
            );

            final statusCard = SizedBox(
              height: double.infinity,
              child: Card(
                elevation: 4,
                margin: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        syncState.isSyncing ? Icons.sync : Icons.cloud_done,
                        size: 64,
                        color: syncState.isSyncing ? Colors.blue : Colors.green,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        syncState.isSyncing ? 'Syncing...' : 'System Ready',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      if (syncState.isSyncing) ...[
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              height: 24,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: LinearProgressIndicator(
                                  value: syncState.progress > 0 ? syncState.progress : null,
                                  minHeight: 24,
                                ),
                              ),
                            ),
                            Text(
                              syncState.status,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.stop, color: Colors.red),
                          label: const Text('STOP SYNC', style: TextStyle(color: Colors.red)),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                            side: const BorderSide(color: Colors.red),
                          ),
                          onPressed: () => ref.read(syncProvider.notifier).cancelSync(),
                        ),
                      ] else ...[
                        Text(syncState.status.isEmpty ? 'Waiting for changes' : syncState.status),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync All Systems'),
                          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
                          onPressed: () => ref.read(syncProvider.notifier).sync(),
                        ),
                      ],
                      if (!syncState.isSyncing && syncState.conflicts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                          label: Text('RESOLVE ${syncState.conflicts.length} CONFLICTS', style: const TextStyle(color: Colors.orange)),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 54),
                            side: const BorderSide(color: Colors.orange),
                          ),
                          onPressed: () => context.push('/conflicts'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 4, child: statusCard),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 6, child: systemsListView),
                ],
              );
            } else {
              return Column(
                children: [
                  statusCard,
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Divider(),
                  ),
                  Expanded(child: systemsListView),
                ],
              );
            }
          });
        },
      ),
    );
  }
}
