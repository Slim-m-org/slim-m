// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A raw `fontSize:` literal that lands off [AppText]'s own scale is how the
/// scale stops being a scale, one contributor at a time; a `FontWeight` past
/// 600 is the same drift on the other axis.
///
/// Found by a sweep, not by any gate: an onboarding dialog carried a bare
/// `fontSize: 13` (between [AppText.caption] and [AppText.ui], on neither),
/// and three more off-scale values sat undiscovered beside it in files
/// nobody was looking at when they touched something else. This is the gate
/// that sweep did not leave behind anywhere else.
///
/// The size check is scoped to `design_system` and `app`, the two packages
/// actually built against [AppText]; `rtc` and `voice_canvas` cannot import
/// it at all (see their own doc comments on why) and are out of that check's
/// reach by construction, not by omission. The weight check has no such
/// seam - every client package can spell `FontWeight.w700` whether or not it
/// can reach [AppWeights] - so it walks every package's `lib/`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A short, named allowlist rather than a growing one: each entry already
/// carries its own one-line "why" in the source, the same discipline this
/// test exists to hold everyone else to.
const _exceptions = {
  // AppChip.reaction's emoji glyph: its own doc comment names the literal.
  'lib/src/components/forms/chip.dart',
  // AppCodeBlock's fenced-block body: its own doc comment names the literal.
  'lib/src/components/surfaces/code_block.dart',
  // A module command's result panel: matches AppCodeBlock's own body size exactly, so output reads as a continuation of the code; its own comment names it.
  '../app/lib/src/features/modules/widgets/module_command_output.dart',
  // FingerprintDisplay's read-aloud hex groups: ported as-is from the source design.
  '../app/lib/src/features/auth/widgets/server_fingerprint_step.dart',
  // The member card's role chip: the design review's own spec names 10pt Mono for it.
  '../app/lib/src/features/members/widgets/member_profile_identity.dart',
};

final _fontSizeLiteral = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');

/// `w700` through `w900`, and the `bold` alias for `w700`.
final _heavyWeight = RegExp(r'FontWeight\.(bold|w[789]00)\b');

void main() {
  test('every raw fontSize literal is on the AppText scale or exempted', () {
    final designSystemLib = Directory('lib');
    expect(
      designSystemLib.existsSync(),
      isTrue,
      reason: 'run this from the design_system package root',
    );

    final scale = _fontSizeLiteral
        .allMatches(File('lib/src/app_typography.dart').readAsStringSync())
        .map((m) => double.parse(m.group(1)!))
        .toSet();
    expect(scale, isNotEmpty, reason: 'could not read the scale itself');

    final appLib = Directory('../app/lib');
    expect(
      appLib.existsSync(),
      isTrue,
      reason: 'expected a sibling app package at ../app',
    );

    final offenders = <String>[];
    for (final dir in [designSystemLib, appLib]) {
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (file.path == 'lib/src/app_typography.dart') continue;
        if (_exceptions.contains(file.path)) continue;
        for (final match in _fontSizeLiteral.allMatches(
          file.readAsStringSync(),
        )) {
          final size = double.parse(match.group(1)!);
          if (!scale.contains(size)) {
            offenders.add('${file.path}: fontSize: ${match.group(1)}');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'off-scale fontSize literal(s) found - use an AppText step, or '
          'add a one-line "why" comment and list the file in _exceptions:\n'
          '${offenders.join('\n')}',
    );
  });

  test('nothing in the client spells a weight past 600', () {
    final packages = Directory('..');
    expect(
      packages.existsSync(),
      isTrue,
      reason: 'run this from the design_system package root',
    );

    final offenders = <String>[];
    for (final pkg in packages.listSync().whereType<Directory>()) {
      final lib = Directory('${pkg.path}/lib');
      if (!lib.existsSync()) continue;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        for (final match in _heavyWeight.allMatches(
          file.readAsStringSync(),
        )) {
          offenders.add('${file.path}: ${match.group(0)}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'a FontWeight past 600 was found; this type system stops at 600 '
          '(see app_typography.dart\'s own doc comment for why):\n'
          '${offenders.join('\n')}',
    );
  });
}
