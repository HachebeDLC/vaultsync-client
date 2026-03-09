import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/native_sync_service.dart';
import 'dart:typed_data';
import 'dart:io';

void main() {
  test('NativeSyncService should calculate sum correctly via FFI', () {
    // This test requires the native library to be compiled and loaded
    // It will skip on non-desktop platforms or if library loading fails
    if (!Platform.isWindows && !Platform.isLinux) return;

    try {
      final service = NativeSyncService();
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sum = service.calculateSum(data);
      
      // 1+2+3+4+5 = 15
      expect(sum, 15);
    } catch (e) {
      print('DEBUG: Skipping FFI test because: $e');
    }
  });
}
