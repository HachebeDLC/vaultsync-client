import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultsync_client/features/auth/presentation/recovery_setup_screen.dart';

void main() {
  testWidgets('RecoverySetupScreen should have 3 question dropdowns', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RecoverySetupScreen(),
        ),
      ),
    );

    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(3));
  });
}
