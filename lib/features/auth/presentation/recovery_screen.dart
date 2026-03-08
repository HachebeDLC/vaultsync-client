import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../domain/auth_provider.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final _emailController = TextEditingController();
  final List<TextEditingController> _answerControllers = [
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  ];

  bool _hasPayload = false;
  String? _recoverySalt;
  String? _encryptedPayload;

  @override
  void dispose() {
    _emailController.dispose();
    for (var c in _answerControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchRecoveryInfo() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    try {
      final info = await ref.read(authRepositoryProvider).fetchRecoveryInfo(email);
      setState(() {
        _hasPayload = true;
        _recoverySalt = info['recovery_salt'];
        _encryptedPayload = info['recovery_payload'];
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching recovery info: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recover Vault')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Zero-Knowledge Recovery',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (!_hasPayload) ...[
              const Text('Enter your email to retrieve your recovery questions.'),
              const SizedBox(height: 32),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _fetchRecoveryInfo,
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
                child: const Text('FETCH RECOVERY INFO'),
              ),
            ] else ...[
              const Text('Please answer your security questions to restore your master key.'),
              const SizedBox(height: 32),
              for (int i = 0; i < 3; i++) ...[
                Text('Question ${i + 1}: [Security questions configured during setup]'),
                const SizedBox(height: 8),
                TextField(
                  controller: _answerControllers[i],
                  decoration: const InputDecoration(labelText: 'Your Answer'),
                ),
                const SizedBox(height: 24),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () async {
                   try {
                     final answers = _answerControllers.map((c) => c.text).toList();
                     await ref.read(authRepositoryProvider).recoverMasterKey(
                       _emailController.text.trim(),
                       answers,
                       _recoverySalt!,
                       _encryptedPayload!,
                     );
                     
                     if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Master key restored! You can now log in.')),
                        );
                        context.go('/auth');
                     }
                   } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Recovery failed: $e')),
                        );
                      }
                   }
                },
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
                child: const Text('RESTORE MASTER KEY'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
