import 'dart:io';
import 'package:path/path.dart' as p;

void main() async {
  final dir = Directory('/media/hachebe/usb/Emulation/roms/psp');
  if (!dir.existsSync()) {
    print("Not found");
    return;
  }
  print("Found dir");
  bool found = false;
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      final name = entity.path.split('/').last.toLowerCase();
      if (name.startsWith('.')) continue;
      final ext = name.contains('.') ? name.split('.').last : '';
      if (ext == 'cso' || ext == 'iso') {
        print("Found ROM: ${entity.path}");
        found = true;
        break;
      }
    }
  }
  print("Has valid ROMs: $found");
}
