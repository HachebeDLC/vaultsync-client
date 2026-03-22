import 'dart:io';
import 'package:path/path.dart' as p;
import 'dart:convert';

void main() async {
  final file = File('/home/hachebe/Smali.Smali/vaultsync_app/assets/systems/snes.json');
  final data = json.decode(await file.readAsString());
  final List<String> exts = List<String>.from(data['system']['extensions']);
  print("SNES exts: $exts");
  
  final dir = Directory('/media/hachebe/usb/Emulation/roms/snes');
  if (!dir.existsSync()) {
    print("SNES Rom dir not found");
    return;
  }
  
  bool found = false;
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      final name = entity.path.split('/').last.toLowerCase();
      if (name.startsWith('.')) continue;
      final ext = name.contains('.') ? name.split('.').last : '';
      if (ext.isNotEmpty && exts.contains(ext)) {
        found = true;
        print("Found ROM: ${entity.path}");
        break;
      }
    }
  }
  print("Has valid ROMs: $found");
}
