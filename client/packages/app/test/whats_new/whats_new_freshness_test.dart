// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gate that stops the what's-new list quietly stopping again.
///
/// It stopped once already and nothing anywhere said so. The newest entry sat
/// at 0.26.0 while twelve releases shipped over the top of it, so
/// `pendingWhatsNewEntries` correctly answered nothing on every one of them
/// and the sheet correctly never appeared. Reading the list tells you nothing
/// about that: a list nobody has added to looks exactly like a list with
/// nothing left to say.
///
/// The comparison is against the version the app really reports - parsed from
/// `client/packages/app/pubspec.yaml`, which is the file `PackageInfo`
/// compiles into the build and the one release-please writes - rather than
/// against a number kept by hand beside the list, which would only ever prove
/// somebody remembered to update two things instead of one.
///
/// [_allowedMinorLag] is what keeps this from forcing a meaningless entry: a
/// release with genuinely nothing a user would notice can be skipped, and so
/// can the one after it. Only a third silent release in a row trips this, and
/// at that point widening the constant with a stated reason is a better
/// answer than inventing an entry nobody needed.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';

/// How many minor releases the newest entry may sit behind the shipped
/// version before this fails.
const _allowedMinorLag = 2;

/// How far ahead the newest entry may be dated. One minor covers the ordinary
/// case of writing an entry for the release this change is going into, which
/// has not bumped the pubspec yet. Past that it is a typo, and a typo here is
/// worse than a missing entry: an entry dated past anything that will ship is
/// never shown by [pendingWhatsNewEntries] and silences this gate forever.
const _allowedMinorLead = 1;

void main() {
  test('the newest entry keeps pace with the version this app reports', () {
    final shipped = _shippedVersion();
    final newest = _parse(whatsNewEntries.last.version);

    expect(
      newest.major,
      shipped.major,
      reason:
          'the newest entry is ${whatsNewEntries.last.version} against a '
          'shipped ${_render(shipped)}; a major bump means every comparison '
          'below is meaningless, so revisit this gate rather than widening it',
    );
    expect(
      shipped.minor - newest.minor,
      lessThanOrEqualTo(_allowedMinorLag),
      reason:
          'the newest what\'s-new entry is ${whatsNewEntries.last.version} '
          'and this app now reports ${_render(shipped)}, so everything since '
          'has shipped with nothing to show for it. Add an entry to '
          'whats_new_content.dart for what a person would actually notice in '
          'those releases. If the releases genuinely had nothing user-facing '
          'in them, raise _allowedMinorLag here and say why.',
    );
  });

  test('the newest entry is not dated past anything that will ship', () {
    final shipped = _shippedVersion();
    final newest = _parse(whatsNewEntries.last.version);

    expect(
      newest.major,
      lessThanOrEqualTo(shipped.major),
      reason:
          'an entry dated into a future major is never shown and hides every '
          'check above it',
    );
    if (newest.major != shipped.major) return;
    expect(
      newest.minor - shipped.minor,
      lessThanOrEqualTo(_allowedMinorLead),
      reason:
          'the newest entry is ${whatsNewEntries.last.version} against a '
          'shipped ${_render(shipped)}; pendingWhatsNewEntries never returns '
          'an entry newer than the running version, so this one would sit '
          'unseen while this file reported the list as healthy',
    );
  });
}

typedef _Version = ({int major, int minor});

String _render(_Version v) => '${v.major}.${v.minor}.x';

_Version _parse(String version) {
  final core = version.split(RegExp(r'[-+]')).first.split('.');
  final major = core.isEmpty ? null : int.tryParse(core.first);
  final minor = core.length < 2 ? null : int.tryParse(core[1]);
  if (major == null || minor == null) {
    fail('could not read a major.minor out of the version "$version"');
  }
  return (major: major, minor: minor);
}

/// The version this build reports through `PackageInfo`, read from the same
/// pubspec the platform reads it from.
_Version _shippedVersion() {
  final pubspec = File(
    '${_findRepoRoot(Directory.current).path}/client/packages/app/pubspec.yaml',
  );
  if (!pubspec.existsSync()) fail('no pubspec at ${pubspec.path}');
  for (final line in pubspec.readAsLinesSync()) {
    if (!line.startsWith('version:')) continue;
    return _parse(line.substring('version:'.length).split('#').first.trim());
  }
  fail('no "version:" line in ${pubspec.path}');
}

/// Walks upward from [start] looking for schema/openapi.yaml, the same
/// repo-root anchor `message_inline_mention_charset_test.dart` already uses,
/// so this does not depend on where the test was invoked from.
Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'could not find schema/openapi.yaml walking up from ${start.path}; is '
    'this test running from somewhere inside the slim-m repo?',
  );
}
