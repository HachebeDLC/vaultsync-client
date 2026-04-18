import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

Future<Directory> _mkProfile(Directory root, String name) async {
  final d = Directory(p.join(root.path, name));
  await d.create(recursive: true);
  return d;
}

Future<File> _touch(Directory dir, String relPath, DateTime mtime) async {
  final f = File(p.join(dir.path, relPath));
  await f.parent.create(recursive: true);
  await f.writeAsString('x');
  await f.setLastModified(mtime);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const probedA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const probedB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const zeroProfile = '00000000000000000000000000000000';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vaultsync_switch_probe_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('returns null when directory does not exist', () async {
    final missing = Directory(p.join(tmp.path, 'nope'));
    expect(
      await SystemPathService.pickActiveProfileFromZeroUserDir(missing),
      isNull,
    );
  });

  test('returns null when only the zero profile exists', () async {
    await _mkProfile(tmp, zeroProfile);
    expect(
      await SystemPathService.pickActiveProfileFromZeroUserDir(tmp),
      isNull,
    );
  });

  test('returns the single non-zero profile without mtime probing', () async {
    await _mkProfile(tmp, zeroProfile);
    await _mkProfile(tmp, probedA);
    expect(
      await SystemPathService.pickActiveProfileFromZeroUserDir(tmp),
      probedA,
    );
  });

  test('picks the profile with the most recently touched subtree', () async {
    final a = await _mkProfile(tmp, probedA);
    final b = await _mkProfile(tmp, probedB);

    // A: a save touched 2 days ago.
    await _touch(
      a,
      '01006F8002326000/save.bin',
      DateTime.now().subtract(const Duration(days: 2)),
    );
    // B: a save touched 10 minutes ago — should win.
    await _touch(
      b,
      '01006F8002326000/save.bin',
      DateTime.now().subtract(const Duration(minutes: 10)),
    );

    expect(
      await SystemPathService.pickActiveProfileFromZeroUserDir(tmp),
      probedB,
    );
  });

  test('ignores non-hex and wrong-length folders', () async {
    await _mkProfile(tmp, 'not-a-profile-at-all');
    await _mkProfile(tmp, '0123'); // too short
    await _mkProfile(tmp, probedA);
    expect(
      await SystemPathService.pickActiveProfileFromZeroUserDir(tmp),
      probedA,
    );
  });

  group('resolveSwitchPackageRootPosix', () {
    test('returns path unchanged when nand/user/save is already direct child',
        () async {
      await Directory(p.join(tmp.path, 'nand', 'user', 'save'))
          .create(recursive: true);
      expect(
        await SystemPathService.resolveSwitchPackageRootPosix(tmp.path),
        tmp.path,
      );
    });

    test('walks into /files when package layout is detected', () async {
      await Directory(p.join(tmp.path, 'files', 'nand', 'user', 'save'))
          .create(recursive: true);
      expect(
        await SystemPathService.resolveSwitchPackageRootPosix(tmp.path),
        p.join(tmp.path, 'files'),
      );
    });

    test('returns input when neither layout exists', () async {
      final bogus = Directory(p.join(tmp.path, 'nothing-here'));
      await bogus.create();
      expect(
        await SystemPathService.resolveSwitchPackageRootPosix(bogus.path),
        bogus.path,
      );
    });

    test('strips trailing slash before probing', () async {
      await Directory(p.join(tmp.path, 'files', 'nand', 'user', 'save'))
          .create(recursive: true);
      final withSlash = '${tmp.path}/';
      expect(
        await SystemPathService.resolveSwitchPackageRootPosix(withSlash),
        p.join(tmp.path, 'files'),
      );
    });
  });
}
