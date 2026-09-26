// Regression coverage for the Azahar/Citra/3DS "saves/saves/" doubling.
//
// Evidence (real device, POCO F8 Pro): a SAF root configured at the
// package/`files` level (see SystemPathService.isPackageFilesDir) already
// scans with a leading `saves/` segment baked into the relative path (e.g.
// `saves/<titleid>/...`), because the POSIX-only auto-correction in
// SystemPathService.getSystemPath skips content:// SAF roots. Before this
// fix, SyncPathResolver.getCloudRelPath's 3DS branch unconditionally
// prepended another `saves/` when no `00040000` title marker was found in
// the path, producing and uploading a doubled
// `3ds/saves/saves/<titleid>/...` cloud path — and getLocalRelPath's mirror
// branch had the same bug on the download side, landing repaired/new files
// in `Azahar/saves/saves/...` instead of `Azahar/saves/...`.
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';

void main() {
  late SyncPathResolver resolver;

  setUp(() {
    resolver = SyncPathResolver();
  });

  group('getCloudRelPath 3DS fallback', () {
    test('does not double an already-anchored saves/ path (package/files-level SAF root)', () {
      final result = resolver.getCloudRelPath('3ds', 'saves/000400000myTitle/00000001.sav');
      expect(result, 'saves/000400000myTitle/00000001.sav');
    });

    test('still prefixes a bare title path with saves/ (EmuDeck/desktop flat structure)', () {
      final result = resolver.getCloudRelPath('azahar', '000400000myTitle/00000001.sav');
      expect(result, 'saves/000400000myTitle/00000001.sav');
    });

    test('citra alias behaves the same as azahar/3ds', () {
      expect(
        resolver.getCloudRelPath('citra', 'saves/anotherTitle/data.bin'),
        'saves/anotherTitle/data.bin',
      );
    });

    test('the 00040000-title-marker branch still takes priority over the fallback', () {
      final result = resolver.getCloudRelPath(
        '3ds',
        'Nintendo 3DS/some-id/some-id2/title/00040000/000c0000/data/00000001/data.bin',
      );
      expect(result, 'saves/000c0000/data/00000001/data.bin');
    });

    test('is case-insensitive when detecting the existing saves/ anchor', () {
      final result = resolver.getCloudRelPath('3ds', 'Saves/title/file.bin');
      expect(result, 'Saves/title/file.bin');
    });
  });

  group('getLocalRelPath 3DS branch stays consistent with the getCloudRelPath fix', () {
    test('does not double saves/ on download when the root is not title/-rooted and cloud path already has it', () {
      // Mirrors a package/files-level SAF root: the scan never sees a
      // title/-prefixed entry, so isRooted is false, and the cloud path
      // (already canonical post-fix) must not get a second saves/ prepended.
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/000400000myTitle/00000001.sav',
        {},
        const [
          {'relPath': 'saves/anotherTitle/data.bin'},
        ],
      );
      expect(result, 'saves/000400000myTitle/00000001.sav');
    });

    test('still prefixes saves/ for a non-anchored cloud path when not title-rooted', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/000400000myTitle/00000001.sav',
        {},
        const [
          {'relPath': 'saves/anotherTitle/data.bin'},
        ],
      );
      expect(result, 'saves/000400000myTitle/00000001.sav');
    });

    test('a title/-rooted scan still strips the saves/ anchor as before', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/000400000myTitle/00000001.sav',
        {},
        const [
          {'relPath': 'title/00040000/000c0000/data/00000001/data.bin'},
        ],
      );
      expect(result, '000400000myTitle/00000001.sav');
    });
  });

  group('getLocalRelPath 3DS: remote-only saves/<titleid>/... mirrors the real sdmc title/00040000 prefix', () {
    // Evidence (real device, POCO F8 Pro): Azahar's 3DS root is
    // `shizuku:///storage/emulated/0/Azahar`, but saves actually live at
    // `Azahar/sdmc/Nintendo 3DS/<id0>/<id1>/title/00040000/<titleid>/...`.
    // A remote-only cloud key `saves/<titleid>/<rest>` used to resolve to
    // `saves/<titleid>/<rest>` (relative to the SAF root), landing at
    // `Azahar/saves/<titleid>/...` where the scanner never looks (it only
    // syncs paths containing `title/00040000`) — so the same file was
    // re-downloaded every sync forever.
    const realLocalSave = {
      'relPath':
          'sdmc/Nintendo 3DS/0000000000000000/0000000000000000/title/00040000/00033c00/data/00000001/progress.sav',
    };

    test('prefix found in local scan -> destination mirrors the sdmc/title/00040000 layout', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/00033600/data/00000001/save00.bin',
        {},
        const [realLocalSave],
      );
      expect(
        result,
        'sdmc/Nintendo 3DS/0000000000000000/0000000000000000/title/00040000/00033600/data/00000001/save00.bin',
      );
    });

    test('title id case from the cloud path is preserved', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/00033C00/data/00000001/save00.bin',
        {},
        const [realLocalSave],
      );
      expect(
        result,
        'sdmc/Nintendo 3DS/0000000000000000/0000000000000000/title/00040000/00033C00/data/00000001/save00.bin',
      );
    });

    test('no local title/00040000 folder in the scan -> falls back to the old (unfixed) behaviour', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/00033600/data/00000001/save00.bin',
        {},
        const [
          {'relPath': 'saves/anotherTitle/data.bin'},
        ],
      );
      // No sdmc title/00040000 evidence anywhere in the scan: keep the
      // pre-existing fallback (not title-rooted, cloud path already
      // saves/-anchored) rather than guessing a prefix.
      expect(result, 'saves/00033600/data/00000001/save00.bin');
    });

    test('multiple distinct prefixes present -> the most common one wins', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/saves/00033600/data/00000001/save00.bin',
        {},
        const [
          {
            'relPath':
                'sdmc/Nintendo 3DS/AAAA/AAAA/title/00040000/00033c00/data/00000001/progress.sav',
          },
          {
            'relPath':
                'sdmc/Nintendo 3DS/AAAA/AAAA/title/00040000/00095500/data/00000001/somsys.bin',
          },
          {
            'relPath':
                'otherRoot/title/00040000/001b5000/data/00000001/main',
          },
        ],
      );
      expect(
        result,
        'sdmc/Nintendo 3DS/AAAA/AAAA/title/00040000/00033600/data/00000001/save00.bin',
      );
    });

    test('cloud key already under title/00040000 -> unchanged (old behaviour), not rewritten', () {
      final result = resolver.getLocalRelPath(
        '3ds',
        '3ds/sdmc/Nintendo 3DS/x/x/title/00040000/00033600/data/00000001/save00.bin',
        {},
        const [realLocalSave],
      );
      // Falls through to the pre-existing logic entirely: isRooted is false
      // (no scan entry starts with 'title/' as its first segment) and the
      // cloud path doesn't start with 'saves/', so the old fallback prepends
      // 'saves/' as it always did.
      expect(
        result,
        'saves/sdmc/Nintendo 3DS/x/x/title/00040000/00033600/data/00000001/save00.bin',
      );
    });

    test('round trip: cloud key -> local destination (with prefix) -> cloud key is identical', () {
      const cloudKey = 'saves/00033600/data/00000001/save00.bin';
      final localDest = resolver.getLocalRelPath(
        '3ds',
        '3ds/$cloudKey',
        {},
        const [realLocalSave],
      );
      expect(localDest, isNotNull);
      final roundTripped = resolver.getCloudRelPath('3ds', localDest!);
      expect(roundTripped, cloudKey);
    });
  });

  group('SyncPathResolver.dealias3dsDoubledSavesRemoteKeys', () {
    test('collapses a leading doubled saves/saves/ key to the canonical single-saves/ key', () {
      final result = SyncPathResolver.dealias3dsDoubledSavesRemoteKeys({
        'saves/saves/myTitle/00000001.sav': {'hash': 'h1'},
      });
      expect(result, {
        'saves/myTitle/00000001.sav': {'hash': 'h1'},
      });
    });

    test('leaves an already-canonical key untouched', () {
      final input = {
        'saves/myTitle/00000001.sav': {'hash': 'h1'},
      };
      expect(SyncPathResolver.dealias3dsDoubledSavesRemoteKeys(input), input);
    });

    test('when both the doubled and canonical keys exist, the canonical one wins and the duplicate is reported', () {
      final canonicalized = <String>[];
      final aliased = <String>[];
      final result = SyncPathResolver.dealias3dsDoubledSavesRemoteKeys(
        {
          'saves/myTitle/00000001.sav': {'hash': 'canonical'},
          'saves/saves/myTitle/00000001.sav': {'hash': 'stale-duplicate'},
        },
        onDuplicate: (canonicalKey, aliasedKey) {
          canonicalized.add(canonicalKey);
          aliased.add(aliasedKey);
        },
      );
      expect(result, {
        'saves/myTitle/00000001.sav': {'hash': 'canonical'},
      });
      expect(canonicalized, ['saves/myTitle/00000001.sav']);
      expect(aliased, ['saves/saves/myTitle/00000001.sav']);
    });

    test('leaves unrelated keys alone', () {
      final input = {
        'someOtherFile.bin': {'hash': 'h1'},
      };
      expect(SyncPathResolver.dealias3dsDoubledSavesRemoteKeys(input), input);
    });

    test('is a no-op (identical map) when no key has the doubled prefix', () {
      final input = <String, dynamic>{
        'saves/a.bin': {'hash': 'h1'},
        'saves/b.bin': {'hash': 'h2'},
      };
      expect(identical(SyncPathResolver.dealias3dsDoubledSavesRemoteKeys(input), input), isTrue);
    });
  });
}
