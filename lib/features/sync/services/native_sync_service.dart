import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef VaultSyncSumNative = Uint32 Function(Pointer<Uint8> data, Int32 length);
typedef VaultSyncSumDart = int Function(Pointer<Uint8> data, int length);

final nativeSyncServiceProvider = Provider<NativeSyncService>((ref) {
  return NativeSyncService();
});

class NativeSyncService {
  late DynamicLibrary _nativeLib;
  late VaultSyncSumDart _vaultsyncSum;

  NativeSyncService() {
    _init();
  }

  void _init() {
    if (Platform.isWindows || Platform.isLinux) {
      _nativeLib = DynamicLibrary.executable();
    } else {
      // Fallback or ignore for other platforms
      return;
    }

    _vaultsyncSum = _nativeLib
        .lookup<NativeFunction<VaultSyncSumNative>>('vaultsync_sum')
        .asFunction();
  }

  int calculateSum(Uint8List data) {
    if (!Platform.isWindows && !Platform.isLinux) return 0;
    
    final pointer = malloc.allocate<Uint8>(data.length);
    final list = pointer.asTypedList(data.length);
    list.setAll(0, data);
    
    try {
      return _vaultsyncSum(pointer, data.length);
    } finally {
      malloc.free(pointer);
    }
  }
}
