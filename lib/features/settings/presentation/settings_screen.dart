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
import '../../sync/services/desktop_background_sync_service.dart';
import 'diagnostics_screen.dart';
import 'dart:io';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  bool _autoSync = false;
  bool _useShizuku = false;
  int _androidSdkVersion = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final url = await ref.read(apiClientProvider).getBaseUrl();
    _urlController.text = url ?? '';
    if (Platform.isAndroid) {
       _androidSdkVersion = await const MethodChannel('com.vaultsync.app/launcher').invokeMethod<int>('getAndroidVersion') ?? 0;
    }
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoSync = prefs.getBool('auto_sync') ?? false;
      _useShizuku = prefs.getBool('use_shizuku') ?? false;
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
      if (Platform.isAndroid) await ref.read(backgroundSyncServiceProvider).enableAutoSync();
    } else {
      if (Platform.isAndroid) await ref.read(backgroundSyncServiceProvider).disableAutoSync();
    }
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
                   trailing: TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('LOGOUT')),
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
                onChanged: (value) => ref.read(themeProvider.notifier).toggleTheme(),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 24, bottom: 8),
                child: Text('SYNC PREFERENCES', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
              ),
              SwitchListTile(
                title: const Text('Auto Sync'),
                value: _autoSync,
                onChanged: _toggleAutoSync,
                secondary: const Icon(Icons.sync),
              ),
              if (Platform.isAndroid && _androidSdkVersion > 33)
                SwitchListTile(
                  title: const Text('Use Shizuku Bridge'),
                  subtitle: const Text('Required for Android 14+ restricted folders'),
                  value: _useShizuku,
                  onChanged: (val) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('use_shizuku', val);
                    setState(() => _useShizuku = val);
                  },
                  secondary: const Icon(Icons.shield_outlined),
                ),
              const Padding(
                padding: EdgeInsets.only(top: 24, bottom: 8),
                child: Text('VAULTSYNC SERVER', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 12)),
              ),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(labelText: 'Server URL', border: OutlineInputBorder(), prefixIcon: Icon(Icons.link)),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  await ref.read(apiClientProvider).setBaseUrl(_urlController.text);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server URL saved')));
                },
                child: const Text('UPDATE SERVER URL'),
              ),
              const Divider(height: 64),
              if (Platform.isAndroid)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const DiagnosticsScreen())),
                    icon: const Icon(Icons.monitor_heart),
                    label: const Text('RUN SYSTEM DIAGNOSTICS'),
                  ),
                ),
              const SizedBox(height: 48),
              Center(child: Text('VaultSync v1.2.1-Handheld', style: TextStyle(color: Colors.grey.shade600, fontSize: 12))),
            ],
          ),
        ),
      ),
    );
  }
}
