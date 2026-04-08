import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../domain/auth_provider.dart';
import '../../../l10n/generated/app_localizations.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _usernameController = TextEditingController();
  bool _isRegistering = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _isLoading = true);
    final email = _emailController.text;
    final password = _passwordController.text;
    final username = _usernameController.text;

    try {
      bool success;
      if (_isRegistering) {
        success = await ref.read(authProvider.notifier).register(email, password, username);
      } else {
        success = await ref.read(authProvider.notifier).login(email, password);
      }

      if (success && mounted) {
        if (_isRegistering) {
          context.go('/recovery-setup');
        } else {
          context.go('/');
        }
      } else if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(_isRegistering ? l10n.registrationFailed : l10n.loginFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isRegistering ? l10n.createAccountTitle : l10n.loginTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.serverSettingsTooltip,
            onPressed: () => context.push('/setup'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_person, size: 80, color: Colors.blue),
                const SizedBox(height: 32),
                if (_isRegistering)
                  TextField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: l10n.usernameLabel,
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.person),
                    ),
                  ),
                if (_isRegistering) const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  decoration: InputDecoration(
                    labelText: l10n.emailLabel,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.email),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: l10n.passwordLabel,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.password),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoading 
                      ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2)) 
                      : Text(_isRegistering ? l10n.createAccountButton : l10n.loginButton, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (!_isRegistering)
                  TextButton(
                    onPressed: () => context.push('/recovery'),
                    child: Text(l10n.forgotPasswordButton),
                  ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _isLoading ? null : () {
                    setState(() {
                      _isRegistering = !_isRegistering;
                    });
                  },
                  child: Text(_isRegistering 
                      ? l10n.alreadyHaveAccount
                      : l10n.dontHaveAccount),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
