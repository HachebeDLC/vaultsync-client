import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
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
import '../../../l10n/generated/app_localizations.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() {
      ref.read(syncProvider.notifier).refreshConflicts();
      _loadAndroidInfo();
      _checkBridgeHealth();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkBridgeHealth();
    }
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
    final l10n = AppLocalizations.of(context)!;
    
    if (!_shizukuStatus!.isRunning) {
       await ref.read(shizukuServiceProvider).openApp();
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.openingShizuku)));
    } else {
       final success = await ref.read(shizukuServiceProvider).requestPermission();
       if (success) {
          _checkBridgeHealth();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.shizukuAuthorized)));
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
        developer.log('UI: Path formatting failed', name: 'VaultSync', level: 900, error: e);
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

  String _getActionLabel(SyncAction action, AppLocalizations l10n) {
    switch (action) {
      case SyncAction.login: return l10n.actionLogin;
      case SyncAction.openShizuku: return l10n.actionFix;
      case SyncAction.reselectFolder: return l10n.actionSettings;
      case SyncAction.checkNetwork: return l10n.actionRetry;
      default: return l10n.actionDismiss;
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final pathsAsync = ref.watch(systemPathsProvider);
    final l10n = AppLocalizations.of(context)!;

    // ACTIONABLE BRIDGE ALERT
    Widget? bridgeAlert;
    if (Platform.isAndroid && !_shizukuEnabled && _androidVersion > 33) { // Android 14+ (API > 33)
       bridgeAlert = _buildActionAlert(
         l10n.bridgeSetupTitle, 
         l10n.bridgeSetupSubtitle(_androidVersion),
         Icons.bolt, 
         Colors.blue.shade700,
         onAction: _enableShizuku,
         actionLabel: l10n.actionSetup,
       );
    } else if (_shizukuEnabled && _shizukuStatus != null) {
       if (!_shizukuStatus!.isRunning) {
          bridgeAlert = _buildActionAlert(
            l10n.shizukuNotRunningTitle, 
            l10n.shizukuNotRunningSubtitle,
            Icons.warning_amber_rounded, 
            Colors.orange.shade800,
            onAction: _fixShizuku,
            actionLabel: l10n.actionOpenApp,
          );
       } else if (!_shizukuStatus!.isAuthorized) {
          bridgeAlert = _buildActionAlert(
            l10n.shizukuPermissionTitle, 
            l10n.shizukuPermissionSubtitle,
            Icons.shield_outlined, 
            Colors.deepOrange,
            onAction: _fixShizuku,
            actionLabel: l10n.actionFixNow,
          );
       }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        scrolledUnderElevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.search), tooltip: l10n.scanLibraryTooltip, onPressed: () => context.push('/library-setup')),
          Consumer(
            builder: (context, ref, _) {
              final unreadCount = ref.watch(notificationLogProvider.notifier).unreadActionableCount;
              return Badge(
                isLabelVisible: unreadCount > 0,
                label: Text(unreadCount.toString()),
                child: IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: _showNotificationCenter,
                  tooltip: l10n.notificationsTooltip,
                ),
              );
            },
          ),
          IconButton(icon: const Icon(Icons.settings_outlined), tooltip: l10n.settingsTooltip, onPressed: () => context.push('/settings')),
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
              actionLabel: _getActionLabel(syncState.syncErrors.first.action, l10n),
            ),
          
          Expanded(
            child: pathsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('${l10n.actionRetry}: $err')),
              data: (paths) {
                if (paths.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(l10n.noSystemsConfigured),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(icon: const Icon(Icons.search), label: Text(l10n.scanLibraryButton), onPressed: () => context.push('/library-setup')),
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
                          Text(syncState.isSyncing ? l10n.syncing : l10n.systemReady, style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 24),
                          if (syncState.isSyncing) ...[
                            LinearProgressIndicator(value: syncState.progress > 0 ? syncState.progress : null),
                            const SizedBox(height: 12),
                            Text(syncState.status, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center, maxLines: 2),
                            const SizedBox(height: 24),
                            OutlinedButton(onPressed: () => ref.read(syncProvider.notifier).cancelSync(), style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50)), child: Text(l10n.stopSyncButton, style: const TextStyle(color: Colors.red))),
                          ] else ...[
                            Text(syncState.status.isEmpty ? l10n.waitingForChanges : syncState.status),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(icon: const Icon(Icons.sync), label: Text(l10n.syncAllButton), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)), onPressed: () => ref.read(syncProvider.notifier).sync()),
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
