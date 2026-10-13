// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a server's advertised capabilities off `/version`.
///
/// The distinction these tests exist for is unknown versus missing. Both are
/// "not present", and treating them the same would have the client tell
/// someone an older server has no safety tools when it has simply never been
/// asked.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Version _version(Map<String, Object?> extra) => Version.fromJson({
      'name': 'slim-m',
      'version': '0.17.0',
      'protocol': 1,
      ...extra,
    });

void main() {
  group('advertised capabilities', () {
    test('a server naming both report and block has its safety tools', () {
      final version = _version({
        'capabilities': ['block', 'report'],
      });
      expect(version.safetyTools, SafetyTools.present);
      expect(version.missingSafetyTools, isEmpty);
    });

    test('a server naming neither is missing both, in a stated order', () {
      final version = _version({'capabilities': <String>[]});
      expect(version.safetyTools, SafetyTools.missing);
      expect(version.missingSafetyTools, ['report', 'block']);
    });

    test('a server naming one is missing only the other', () {
      final version = _version({
        'capabilities': ['block'],
      });
      expect(version.safetyTools, SafetyTools.missing);
      expect(version.missingSafetyTools, ['report']);
    });

    test('a server too old to answer is unknown, never missing', () {
      final version = _version({});
      expect(version.capabilities, isNull);
      expect(version.safetyTools, SafetyTools.unknown);
    });

    test('a capability list that is not a list is unknown too', () {
      expect(
        _version({'capabilities': 'report,block'}).safetyTools,
        SafetyTools.unknown,
      );
    });

    test(
        'a capability the client does not know about is carried, not '
        'dropped, and does not count as a safety tool', () {
      final version = _version({
        'capabilities': ['block', 'report', 'something-new'],
      });
      expect(version.capabilities, contains('something-new'));
      expect(version.safetyTools, SafetyTools.present);
    });
  });

  group('gif search', () {
    test('a server offering it reports true', () {
      expect(_version({'gif_search_enabled': true}).gifSearchEnabled, true);
    });

    test('a server without it configured reports false', () {
      expect(_version({'gif_search_enabled': false}).gifSearchEnabled, false);
    });

    test('a server too old to report it is null, not false', () {
      expect(_version({}).gifSearchEnabled, isNull);
    });
  });

  group('link previews', () {
    test('a server offering it reports true', () {
      expect(
        _version({'link_previews_enabled': true}).linkPreviewsEnabled,
        true,
      );
    });

    test('a server without it configured reports false', () {
      expect(
        _version({'link_previews_enabled': false}).linkPreviewsEnabled,
        false,
      );
    });

    test('a server too old to report it is null, not false', () {
      expect(_version({}).linkPreviewsEnabled, isNull);
    });
  });

  group('space name', () {
    test('the admin-chosen name is what a member sees', () {
      final version = _version({'space_name': "Nick's place"});
      expect(version.displayName, "Nick's place");
      expect(version.name, 'slim-m');
    });

    test('a server too old to send one falls back to its name', () {
      expect(_version({}).spaceName, isNull);
      expect(_version({}).displayName, 'slim-m');
    });
  });
}
