import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:vaultsync_client/features/sync/data/switch_profile_resolver.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockSystemPathService extends Mock implements SystemPathService {}

Map<String, dynamic> _f(String relPath) => {
      'relPath': relPath,
      'name': relPath.split('/').last,
      'isDirectory': false,
      'uri': '',
      'size': 0,
      'lastModified': 0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const probed = 'deadbeefcafef00ddeadbeefcafef00d';
  const otherProfile = '1234567890abcdef1234567890abcdef';
  const zeroProfile = '00000000000000000000000000000000';
  const acnh = '01006F8002326000';
  const ringFit = '01002FF008C24000';
  const nonDevice = '0100000000010000'; // not in the device-save set

  group('isValidTitleId', () {
    test('accepts 01 + 14 hex', () {
      expect(SwitchProfileResolver.isValidTitleId(acnh), isTrue);
      expect(SwitchProfileResolver.isValidTitleId('0101000000000000'), isTrue);
      expect(SwitchProfileResolver.isValidTitleId('01AbCdEf00000000'), isTrue);
    });

    test('rejects wrong prefix / length / non-hex', () {
      expect(SwitchProfileResolver.isValidTitleId('02006F8002326000'), isFalse);
      expect(SwitchProfileResolver.isValidTitleId('01006F80'), isFalse);
      expect(SwitchProfileResolver.isValidTitleId('01006F800232600G'), isFalse);
      expect(SwitchProfileResolver.isValidTitleId(''), isFalse);
    });

    test('rejects path-segment names like nand/user/save', () {
      expect(SwitchProfileResolver.isValidTitleId('nand'), isFalse);
      expect(SwitchProfileResolver.isValidTitleId('user'), isFalse);
      expect(SwitchProfileResolver.isValidTitleId('save'), isFalse);
    });
  });

  group('isDeviceSave', () {
    test('accepts known device-save title IDs, case-insensitive', () {
      expect(SwitchProfileResolver.isDeviceSave(acnh), isTrue);
      expect(SwitchProfileResolver.isDeviceSave(ringFit), isTrue);
      expect(SwitchProfileResolver.isDeviceSave(acnh.toLowerCase()), isTrue);
    });

    test('rejects non-device titles and empty', () {
      expect(SwitchProfileResolver.isDeviceSave(nonDevice), isFalse);
      expect(SwitchProfileResolver.isDeviceSave(''), isFalse);
    });
  });

  group('applyProfileFixes', () {
    late MockSystemPathService pathService;
    late SwitchProfileResolver resolver;

    setUp(() {
      pathService = MockSystemPathService();
      resolver = SwitchProfileResolver(pathService);
    });

    test('null probe returns list unchanged', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => null);

      final input = [
        _f('nand/user/save/0000000000000000/$otherProfile/$nonDevice/save.bin'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(out, hasLength(1));
    });

    test('non-device save under probed profile is kept', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      final input = [
        _f('nand/user/save/0000000000000000/$probed/$nonDevice/save.bin'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(
        out.any((f) => (f['relPath'] as String).contains(nonDevice)),
        isTrue,
      );
    });

    test('non-device save under wrong profile is rejected', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      final input = [
        _f('nand/user/save/0000000000000000/$otherProfile/$nonDevice/save.bin'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(
        out.any((f) => (f['relPath'] as String).contains(otherProfile)),
        isFalse,
        reason: 'stray non-device save in wrong profile should be stripped',
      );
    });

    test('device save under zero-user/zero-profile is kept', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      final input = [
        _f('nand/user/save/0000000000000000/$zeroProfile/$acnh/save.dat'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(
        out.any((f) => (f['relPath'] as String).contains(acnh)),
        isTrue,
        reason: 'ACNH is a device save — must survive the profile filter',
      );
    });

    test('device save NOT under zero/zero is rejected', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      // ACNH placed under the user's profile instead of the device bucket.
      final input = [
        _f('nand/user/save/0000000000000000/$probed/$acnh/save.dat'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(
        out.any((f) => (f['relPath'] as String).contains(acnh)),
        isFalse,
        reason: 'device saves must live under zeroUser/zeroProfile',
      );
    });

    test('stray 32-hex profile under zeroUser is stripped', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      // A stray byte-reversed profile directory (common Eden/Argosy artifact)
      // that has no title ID underneath.
      final input = [
        _f('nand/user/save/0000000000000000/$otherProfile/orphan.tmp'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      expect(
        out.any((f) => (f['relPath'] as String).contains(otherProfile)),
        isFalse,
      );
    });

    test('correct profile entry is injected when missing', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      // Start with an empty scan result — fixer should add the correct prefix.
      final out =
          await resolver.applyProfileFixes(<dynamic>[], '/emu/switch');
      final hasProbedEntry = out.any((f) =>
          ((f['relPath'] as String?) ?? '').contains('/$probed'));
      expect(hasProbedEntry, isTrue,
          reason: 'resolver must inject the probed profile folder');
    });

    test('does not duplicate the probed profile if already present', () async {
      when(() => pathService.probeProfileId(any()))
          .thenAnswer((_) async => probed);

      final input = [
        _f('nand/user/save/0000000000000000/$probed/$nonDevice/save.bin'),
      ];
      final out = await resolver.applyProfileFixes(input, '/emu/switch');
      final probedEntries = out.where(
        (f) => (f['relPath'] as String) ==
            'nand/user/save/0000000000000000/$probed',
      );
      expect(probedEntries, isEmpty,
          reason:
              'the existing file under the probed profile already satisfies the prefix');
    });
  });
}
