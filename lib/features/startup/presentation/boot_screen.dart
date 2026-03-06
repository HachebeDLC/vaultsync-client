import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/api_client_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/system_path_service.dart';

class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});

  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> {
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final client = ref.read(apiClientProvider);
    final isConfigured = await client.isConfigured();
    
    if (!mounted) return;

    if (!isConfigured) {
      context.go('/setup');
      return;
    }

    try {
      final baseUrl = await client.getBaseUrl();
      if (baseUrl == null || baseUrl.isEmpty) {
        context.go('/setup');
        return;
      }

      print('🌐 BOOT: Checking connectivity to $baseUrl');
      
      // Attempt Auth initialization
      await ref.read(authProvider.notifier).init();
      
      if (!mounted) return;

      if (ref.read(authProvider.notifier).isAuthenticated) {
        final paths = await ref.read(systemPathServiceProvider).getAllSystemPaths();
        if (!mounted) return;
        
        if (paths.isEmpty) {
          context.go('/library-setup');
        } else {
          context.go('/dashboard');
        }
      } else {
        // Not authenticated, but server might be unreachable due to device lock.
        // We go to /auth anyway; the login/register screen can handle retries.
        context.go('/auth');
      }
    } catch (e) {
      print('ℹ️ BOOT: Network restricted (likely device lock). Proceeding to Auth screen.');
      if (mounted) {
        // If we have a URL but just couldn't reach it, don't force setup.
        // Let the user land on Auth where they can manually retry or wait for signal.
        context.go('/auth');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'Initializing VaultSync...',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      ),
    );
  }
}
