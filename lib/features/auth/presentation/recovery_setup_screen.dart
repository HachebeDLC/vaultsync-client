import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RecoverySetupScreen extends ConsumerStatefulWidget {
  const RecoverySetupScreen({super.key});

  @override
  ConsumerState<RecoverySetupScreen> createState() => _RecoverySetupScreenState();
}

class _RecoverySetupScreenState extends ConsumerState<RecoverySetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final List<String> _questions = [
    'What was the name of your first pet?',
    'What is your mother\'s maiden name?',
    'What city were you born in?',
    'What was the name of your elementary school?',
    'What was the make of your first car?',
    'What is your favorite book?',
  ];

  final List<String?> _selectedQuestions = [null, null, null];
  final List<TextEditingController> _controllers = [
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  ];

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Setup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Setup Recovery Fail-Safe',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'These questions will allow you to recover your vault if you lose your password. Your answers are encrypted and never sent to the server in plaintext.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              for (int i = 0; i < 3; i++) ...[
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(labelText: 'Question ${i + 1}'),
                  items: _questions.map((q) => DropdownMenuItem(value: q, child: Text(q))).toList(),
                  onChanged: (val) => setState(() => _selectedQuestions[i] = val),
                  validator: (val) => val == null ? 'Please select a question' : null,
                ),
                TextFormField(
                  controller: _controllers[i],
                  decoration: const InputDecoration(labelText: 'Your Answer'),
                  validator: (val) => (val == null || val.isEmpty) ? 'Answer is required' : null,
                ),
                const SizedBox(height: 24),
              ],
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    // Logic to follow in next task
                  }
                },
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
                child: const Text('SAVE RECOVERY SETUP'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
