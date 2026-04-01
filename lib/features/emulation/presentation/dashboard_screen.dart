import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../sync/domain/sync_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/shizuku_service.dart';
import '../../../core/errors/error_mapper.dart';
import '../../sync/domain/notification_provider.dart';
import '../../sync/presentation/notification_center_sheet.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  void _showNotificationCenter() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const NotificationCenterSheet(),
    );
    ref.read(notificationLogProvider.notifier).markAllAsRead();
  }

  ShizukuStatus? _shizukuStatus;
  bool _shizukuEnabled = false;
  int _androidVersion = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(syncProvider.notifier).refreshConflicts();
      _loadAndroidInfo();
      _checkBridgeHealth();
    });
  }

  Future<void> _loadAndroidInfo() async {
    if (!Platform.isAndroid) return;
    final version = await ref.read(shizukuServiceProvider).getAndroidVersion();
    if (mounted) {
      setState(() => _androidVersion = version);
    }
  }

  Future<void> _checkBridgeHealth() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('use_shizuku') ?? false;
    final status = await ref.read(shizukuServiceProvider).getStatus();
    
    if (mounted) {
      setState(() {
        _shizukuEnabled = enabled;
        _shizukuStatus = status;
      });
    }
  }

  Future<void> _enableShizuku() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_shizuku', true);
    if (mounted) {
      setState(() => _shizukuEnabled = true);
      ref.invalidate(systemPathsProvider);
      _checkBridgeHealth();
    }
  }

  Future<void> _fixShizuku() async {
    if (_shizukuStatus == null) return;
    
    if (!_shizukuStatus!.isRunning) {
       await ref.read(shizukuServiceProvider).openApp();
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Opening Shizuku... Start the service and come back.')));
    } else {
       final success = await ref.read(shizukuServiceProvider).requestPermission();
       if (success) {
          _checkBridgeHealth();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Shizuku authorized!')));
       }
    }
  }

  String _formatSafPath(String path) {
    if (path.startsWith('content://')) {
      try {
        final decoded = Uri.decodeComponent(path);
        if (decoded.contains('primary:')) return '/storage/emulated/0/${decoded.split('primary:').last}';
        return decoded.split('/').last;
      } catch (e) {
        print('⚠️ UI: Path formatting failed: $e');
      }
    }
    return path;
  }

  Widget _getSystemIconWidget(String systemId, {double size = 24}) {
    final id = systemId.toLowerCase();
    String iconName = 'controller';
    if (id.contains('ps2') || id.contains('aethersx2') || id.contains('nethersx2')) {
      iconName = 'playstation';
    } else if (id.contains('gba') || id.contains('gbc') || id.contains('gb')) iconName = 'gameboy';
    else if (id.contains('gc') || id.contains('dolphin')) iconName = 'gc';
    else if (id.contains('3ds') || id.contains('citra')) iconName = 'nintendo3ds';
    else if (id.contains('ds') || id.contains('melonds')) iconName = 'ds';
    else if (id.contains('switch') || id.contains('eden')) iconName = 'nintendoswitch';
    else if (id.contains('psp') || id.contains('ppsspp')) iconName = 'psp';

    try {
      return SvgPicture.asset(
        'assets/systems/$iconName.svg',
        width: size, height: size,
        colorFilter: const ColorFilter.mode(Colors.blue, BlendMode.srcIn),
        placeholderBuilder: (context) => const Icon(Icons.folder, size: 24, color: Colors.blue),
      );
    } catch (_) {
      return const Icon(Icons.folder, size: 24, color: Colors.blue);
    }
  }

  String _getActionLabel(SyncAction action) {
    switch (action) {
      case SyncAction.login: return 'LOGIN';
      case SyncAction.openShizuku: return 'FIX';
      case SyncAction.reselectFolder: return 'SETTINGS';
      case SyncAction.checkNetwork: return 'RETRY';
      default: return 'DISMISS';
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final pathsAsync = ref.watch(systemPathsProvider);

    // ACTIONABLE BRIDGE ALERT
    Widget? bridgeAlert;
    if (Platform.isAndroid && !_shizukuEnabled && _androidVersion > 33) { // Android 14+ (API > 33)
       bridgeAlert = _buildActionAlert(
         'Recommended: Setup Bridge', 
         'Shizuku is required for full speed on Android $_androidVersion',
         Icons.bolt, 
         Colors.blue.shade700,
         onAction: _enableShizuku,
         actionLabel: 'SETUP',
       );
    } else if (_shizukuEnabled && _shizukuStatus != null) {
       if (!_shizukuStatus!.isRunning) {
          bridgeAlert = _buildActionAlert(
            'Shizuku is not running', 
            'restricted folder access is disabled',
            Icons.warning_amber_rounded, 
            Colors.orange.shade800,
            onAction: _fixShizuku,
            actionLabel: 'OPEN APP',
          );
       } else if (!_shizukuStatus!.isAuthorized) {
          bridgeAlert = _buildActionAlert(
            'Shizuku Permission Required', 
            'authorize VaultSync to continue',
            Icons.shield_outlined, 
            Colors.deepOrange,
            onAction: _fixShizuku,
            actionLabel: 'FIX NOW',
          );
       }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('VaultSync'),
        scrolledUnderElevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.search), tooltip: 'Scan Library', onPressed: () => context.push('/library-setup')),
          Consumer(
            builder: (context, ref, _) {
              final unreadCount = ref.watch(notificationLogProvider.notifier).unreadActionableCount;
              return Badge(
                isLabelVisible: unreadCount > 0,
                label: Text(unreadCount.toString()),
                child: IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: _showNotificationCenter,
                  tooltip: 'Notifications',
                ),
              );
            },
          ),
          IconButton(icon: const Icon(Icons.settings_outlined), tooltip: 'Settings', onPressed: () => context.push('/settings')),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (bridgeAlert != null) bridgeAlert,
          if (syncState.syncErrors.isNotEmpty && bridgeAlert == null)
            _buildActionAlert(
              syncState.syncErrors.first.title, 
              syncState.syncErrors.first.message,
              Icons.error_outline, 
              Colors.red.shade900,
              onAction: () {
                final error = syncState.syncErrors.first;
                if (error.action == SyncAction.login) {
                  context.push('/auth');
                } else if (error.action == SyncAction.reselectFolder) {
                  context.push('/settings');
                } else if (error.action == SyncAction.openShizuku) {
                  _fixShizuku();
                } else if (error.action == SyncAction.checkNetwork) {
                  ref.read(syncProvider.notifier).sync();
                }
                ref.read(syncProvider.notifier).clearErrors();
              },
              actionLabel: _getActionLabel(syncState.syncErrors.first.action),
            ),
          
          Expanded(
            child: pathsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('Error: $err')),
              data: (paths) {
                if (paths.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('No systems configured yet.'),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(icon: const Icon(Icons.search), label: const Text('Scan Library'), onPressed: () => context.push('/library-setup')),
                      ],
                    ),
                  );
                }

                return LayoutBuilder(builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 600;
                  
                  final systemsListView = ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: paths.length,
                    itemBuilder: (context, index) {
                      final entry = paths.entries.elementAt(index);
                      final systemId = entry.key;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => context.push('/system-detail/$systemId'),
                          leading: CircleAvatar(backgroundColor: Colors.blue.withOpacity(0.1), child: _getSystemIconWidget(systemId)),
                          title: Text(systemId.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(_formatSafPath(entry.value), maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                        ),
                      );
                    },
                  );

                  final statusCard = Card(
                    elevation: 4,
                    margin: const EdgeInsets.all(16),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(syncState.isSyncing ? Icons.sync : Icons.cloud_done, size: 64, color: syncState.isSyncing ? Colors.blue : Colors.green),
                          const SizedBox(height: 16),
                          Text(syncState.isSyncing ? 'Syncing...' : 'System Ready', style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 24),
                          if (syncState.isSyncing) ...[
                            LinearProgressIndicator(value: syncState.progress > 0 ? syncState.progress : null),
                            const SizedBox(height: 12),
                            Text(syncState.status, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center, maxLines: 2),
                            const SizedBox(height: 24),
                            OutlinedButton(onPressed: () => ref.read(syncProvider.notifier).cancelSync(), style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50)), child: const Text('STOP SYNC', style: TextStyle(color: Colors.red))),
                          ] else ...[
                            Text(syncState.status.isEmpty ? 'Waiting for changes' : syncState.status),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(icon: const Icon(Icons.sync), label: const Text('Sync All'), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)), onPressed: () => ref.read(syncProvider.notifier).sync()),
                          ],
                        ],
                      ),
                    ),
                  );

                  if (isWide) {
                    return Row(
                      children: [
                        Expanded(flex: 2, child: SingleChildScrollView(child: statusCard)),
                        const VerticalDivider(width: 1),
                        Expanded(flex: 3, child: systemsListView),
                      ],
                    );
                  }
                  return Column(children: [statusCard, const Divider(), Expanded(child: systemsListView)]);
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionAlert(String title, String subtitle, IconData icon, Color color, {required VoidCallback onAction, required String actionLabel}) {
     return Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: onAction, 
                style: ElevatedButton.styleFrom(
                  backgroundColor: color, 
                  foregroundColor: Colors.white,
                  elevation: 0,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ],
          ),
        ),
     );
  }
}
