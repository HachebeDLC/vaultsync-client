import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/services/api_client_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/sync_service.dart';
import '../../sync/services/background_sync_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  bool _autoSync = false;
  bool _intelligentSync = false;
  bool _isWiping = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final url = await ref.read(apiClientProvider).getBaseUrl();
    _urlController.text = url ?? '';

    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoSync = prefs.getBool('auto_sync') ?? false;
      _intelligentSync = prefs.getBool('intelligent_sync') ?? false;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _toggleAutoSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync', value);
    setState(() => _autoSync = value);

    if (value) {
      await ref.read(backgroundSyncServiceProvider).enableAutoSync();
    } else {
      await ref.read(backgroundSyncServiceProvider).disableAutoSync();
    }
  }

  Future<void> _toggleIntelligentSync(bool value) async {
    if (value) {
      // Check permission
      final platform = MethodChannel('com.vaultsync.app/launcher');
      final bool hasPermission = await platform.invokeMethod('hasUsageStatsPermission');
      
      if (!hasPermission && mounted) {
        final grant = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text('Intelligent Sync needs "Usage Access" permission to detect when you close an emulator and trigger an immediate backup. \n\nPlease enable it for VaultSync in the next screen.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OPEN SETTINGS')),
            ],
          ),
        );

        if (grant == true) {
          await platform.invokeMethod('openUsageStatsSettings');
          // We don't enable it yet, user needs to toggle again after granting
          return;
        } else {
          return;
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('intelligent_sync', value);
    setState(() => _intelligentSync = value);
  }

  Future<void> _wipeCloudData() async {
    // 1st Check: Basic Intent
    final check1 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nuclear Option: Wipe Cloud?'),
        content: const Text('This will delete all saves and hidden versions on the VaultSync Server. Your local files will NOT be affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('NEXT')),
        ],
      ),
    );
    if (check1 != true) return;

    // 2nd Check: Data Loss Warning
    if (!mounted) return;
    final check2 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Data Deletion'),
        content: const Text('WARNING: This includes ALL previous file versions and history. You will lose the ability to restore any cloud backups.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('GO BACK')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('I UNDERSTAND')),
        ],
      ),
    );
    if (check2 != true) return;

    // 3rd Check: Final Confirmation
    if (!mounted) return;
    final check3 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.red.shade900,
        title: const Text('FINAL CONFIRMATION', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This action is IRREVERSIBLE. All data for this account on the server will be purged.\n\nProceed with total wipe?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false), 
            child: const Text('ABORT', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.red.shade900),
            child: const Text('ERASE EVERYTHING'),
          ),
        ],
      ),
    );
    if (check3 != true) return;

    setState(() => _isWiping = true);
    try {
      final syncService = ref.read(syncServiceProvider);
      final response = await ref.read(apiClientProvider).get('/api/v1/files');
      final List<dynamic> files = response['files'] ?? [];
      final systems = files.map((f) => (f['path'] as String).split('/').first).toSet();
      
      for (final systemId in systems) {
         await syncService.deleteSystemCloudData(systemId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('VaultSync Server has been purged.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isWiping = false);
    }
  }

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);
    final user = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24.0),
            children: [
              if (user != null) ...[
                 ListTile(
                   leading: const CircleAvatar(child: Icon(Icons.person)),
                   title: Text(user.email),
                   subtitle: const Text('Logged in'),
                   trailing: TextButton(onPressed: _logout, child: const Text('LOGOUT')),
                 ),
                 const Divider(),
              ],
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 8),
                child: Text('APPEARANCE', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
              ),
              SwitchListTile(
                title: const Text('Dark Mode'),
                secondary: const Icon(Icons.dark_mode),
                value: themeMode == ThemeMode.dark,
                onChanged: (value) {
                  ref.read(themeProvider.notifier).toggleTheme();
                },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 24, bottom: 8),
                child: Text('SYNC PREFERENCES', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
              ),
              SwitchListTile(
                title: const Text('Auto Sync (Background)'),
                subtitle: const Text('Periodically sync files when idle'),
                secondary: const Icon(Icons.sync_outlined),
                value: _autoSync,
                onChanged: _toggleAutoSync,
              ),
              SwitchListTile(
                title: const Text('Intelligent Sync (Experimental)'),
                subtitle: const Text('Sync immediately when an emulator closes'),
                secondary: const Icon(Icons.bolt_outlined),
                value: _intelligentSync,
                onChanged: _toggleIntelligentSync,
              ),
              const Padding(
                padding: EdgeInsets.only(top: 24, bottom: 8),
                child: Text('VAULTSYNC SERVER', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
              ),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://vaultsync.example.com',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  await ref.read(apiClientProvider).setBaseUrl(_urlController.text);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Server URL saved')),
                    );
                  }
                },
                child: const Text('UPDATE SERVER URL'),
              ),
              const Divider(height: 64),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text('MAINTENANCE',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 12)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _isWiping ? null : _wipeCloudData,
                icon: _isWiping 
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red))
                    : const Icon(Icons.delete_forever),
                label: const Text('WIPE ALL CLOUD DATA', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 48),
              Center(
                child: Text(
                  'VaultSync v1.1-Stable',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
