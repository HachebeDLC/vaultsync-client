// Tests for the Switch/Eden "package root" SAF migration.
//
// Evidence (real device, Retroid Pocket Nova, Android 13): the Switch folder
// pref (`system_path_switch`) was set to the SAF tree for the *package*
// directory itself —
//   content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator
// — instead of its `files` subfolder, where Eden actually keeps saves. The
// native scanner's Switch filter skips any top-level entry that isn't
// `nand`/`user`/`save`/…, so `files/` was never scanned from that root.
//
// [SystemPathService.packageRootFilesTreeUri] recognizes exactly that shape
// and computes the corresponding `/files` tree URI; unproven, without an
// actual persisted grant, `decidePackageRootMigration` refuses to switch to
// it and blocked/is-safe rather than guessing.
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

void main() {
  group('packageRootFilesTreeUri', () {
    test('computes the /files tree URI for an exact package-root tree', () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
      const expected =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Ffiles';

      expect(SystemPathService.packageRootFilesTreeUri(input), expected);
    });

    test('works for any package name (e.g. yuzu)', () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Forg.yuzu.yuzu_emu';
      const expected =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Forg.yuzu.yuzu_emu%2Ffiles';

      expect(SystemPathService.packageRootFilesTreeUri(input), expected);
    });

    test('returns null when already at /files', () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Ffiles';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });

    test('returns null for a deeper path under /files', () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Ffiles%2Fnand';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });

    test('returns null for a non-SAF POSIX path', () {
      expect(
          SystemPathService.packageRootFilesTreeUri(
              '/storage/emulated/0/Android/data/dev.eden.eden_emulator'),
          isNull);
    });

    test('returns null for a shizuku:// path', () {
      expect(
          SystemPathService.packageRootFilesTreeUri(
              'shizuku:///storage/emulated/0/Android/data/dev.eden.eden_emulator'),
          isNull);
    });

    test('returns null for a SAF tree from a different document provider',
        () {
      const input =
          'content://com.android.providers.downloads.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });

    test('returns null for a tree rooted somewhere other than Android/data',
        () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3ARetroArch%2Fsaves';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });

    test('returns null for a non-primary volume', () {
      const input =
          'content://com.android.externalstorage.documents/tree/1234-5678%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });

    test('returns null for a child-document URI appended after the tree segment',
        () {
      const input =
          'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator/document/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
      expect(SystemPathService.packageRootFilesTreeUri(input), isNull);
    });
  });

  group('decidePackageRootMigration', () {
    const packageRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
    const filesUri =
        'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Ffiles';

    test('migrates when a grant for /files is already held', () {
      final result = SystemPathService.decidePackageRootMigration(
          packageRoot,
          grantHeld: true);
      expect(result.outcome, PackageRootMigrationOutcome.migrated);
      expect(result.migratedPath, filesUri);
    });

    test('blocks (and leaves the path alone) when no grant for /files is held',
        () {
      final result = SystemPathService.decidePackageRootMigration(
          packageRoot,
          grantHeld: false);
      expect(result.outcome, PackageRootMigrationOutcome.blockedNoGrant);
      expect(result.migratedPath, isNull);
    });

    test('is not applicable when already at /files, regardless of grant', () {
      final result =
          SystemPathService.decidePackageRootMigration(filesUri, grantHeld: true);
      expect(result.outcome, PackageRootMigrationOutcome.notApplicable);

      final result2 = SystemPathService.decidePackageRootMigration(filesUri,
          grantHeld: false);
      expect(result2.outcome, PackageRootMigrationOutcome.notApplicable);
    });

    test('is not applicable for a non-package-root path', () {
      final result = SystemPathService.decidePackageRootMigration(
          '/storage/emulated/0/RetroArch/saves',
          grantHeld: true);
      expect(result.outcome, PackageRootMigrationOutcome.notApplicable);
    });
  });

  group('packageRootFilesPosixPath', () {
    test('computes the /files path for an exact POSIX package root', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/Android/data/me.magnum.melonds'),
          '/storage/emulated/0/Android/data/me.magnum.melonds/files');
    });

    test('works for any package name', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/Android/data/dev.eden.eden_emulator'),
          '/storage/emulated/0/Android/data/dev.eden.eden_emulator/files');
    });

    test('trims a trailing slash before matching', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/Android/data/me.magnum.melonds/'),
          '/storage/emulated/0/Android/data/me.magnum.melonds/files');
    });

    test('returns null when already at /files', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/Android/data/me.magnum.melonds/files'),
          isNull);
    });

    test('returns null for a deeper path under /files', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/Android/data/me.magnum.melonds/files/saves'),
          isNull);
    });

    test('returns null for a content:// URI', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fme.magnum.melonds'),
          isNull);
    });

    test('returns null for a path not rooted at Android/data', () {
      expect(
          SystemPathService.packageRootFilesPosixPath(
              '/storage/emulated/0/RetroArch/saves'),
          isNull);
    });
  });

  group('isPackageFilesDir', () {
    test('true for a POSIX package files/ root', () {
      expect(
          SystemPathService.isPackageFilesDir(
              '/storage/emulated/0/Android/data/me.magnum.melonds/files'),
          isTrue);
    });

    test('true for the same path via shizuku://', () {
      expect(
          SystemPathService.isPackageFilesDir(
              'shizuku:///storage/emulated/0/Android/data/me.magnum.melonds/files'),
          isTrue);
    });

    test('true for the equivalent SAF tree URI', () {
      expect(
          SystemPathService.isPackageFilesDir(
              'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fme.magnum.melonds%2Ffiles'),
          isTrue);
    });

    test('false for the package root itself (no /files)', () {
      expect(
          SystemPathService.isPackageFilesDir(
              '/storage/emulated/0/Android/data/me.magnum.melonds'),
          isFalse);
    });

    test('false for a subfolder under /files', () {
      expect(
          SystemPathService.isPackageFilesDir(
              '/storage/emulated/0/Android/data/me.magnum.melonds/files/saves'),
          isFalse);
    });

    test('false for an unrelated path', () {
      expect(
          SystemPathService.isPackageFilesDir('/storage/emulated/0/RetroArch/saves'),
          isFalse);
    });
  });
}
