// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A raw `LucideIcons.`, Material `Icons.` or `CupertinoIcons.` reference
/// outside [AppIcons] is how the icon vocabulary stops being one vocabulary,
/// one call site at a time - the same drift [type_scale_literal_test]
/// already gates on the type scale.
///
/// `app/lib` cannot import `lucide_icons_flutter` at all (only
/// `design_system` depends on it, per each package's own `pubspec.yaml`), so
/// the Lucide half of this gate mostly guards against a future widget added
/// inside `design_system` itself reaching past [AppIcons]. The other two have
/// real reach today: `Icons.*` ships bundled with `package:flutter/material.dart`,
/// already imported almost everywhere, and `CupertinoIcons.*` needs no pubspec
/// dependency at all - it is defined in the Flutter SDK's own
/// `package:flutter/cupertino.dart`, one import away from any file. Nothing
/// stops a raw `Icon(Icons.close)` or `Icon(CupertinoIcons.heart)` from
/// compiling today.
///
/// Nor does naming `Icons`/`CupertinoIcons` at all: `IconData` is the class
/// both of those are just named constant instances of, and constructing one
/// directly from a bare codepoint (`IconData(0xe5cd, fontFamily:
/// 'MaterialIcons')`) reaches the identical glyph with neither name in the
/// source text - reproduced directly, a planted `IconData(...)` literal in
/// `design_system/lib` passed this gate silently before the third pattern
/// below existed. Every legitimate reason to construct one still belongs in
/// [AppIcons], the same as every other icon source this gate names.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

/// Files allowed to reference an icon package directly, each with its own
/// one-line why. Empty on purpose: a widget that needs a glyph belongs in
/// [AppIcons], not at its own call site.
const _exceptions = <String>{};

final _lucideReference = RegExp(r'LucideIcons\.\w+');

/// A named provider matched in full, never by a bare `\bIcons\.` boundary
/// check alone: that shape missed `CupertinoIcons.heart` outright, since
/// there is no word boundary between the `o` and the `I` of that identifier
/// either - the same non-boundary `AppIcons.` already relies on to stay
/// unmatched. Reproduced directly: a `CupertinoIcons.heart` reference
/// planted in `design_system/lib` passed this gate silently before this list
/// grew a third entry, and a bare `IconData(...)` construction did the same
/// before it grew a fourth - see this file's own library doc.
final _iconProviderReferences = [
  RegExp(r'\bIcons\.\w+'),
  RegExp(r'CupertinoIcons\.\w+'),
  RegExp(r'\bIconData\('),
];

Iterable<File> _clientSources() sync* {
  for (final pkg in Directory('..').listSync().whereType<Directory>()) {
    final lib = Directory('${pkg.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) yield file;
    }
  }
}

/// One entry per raw icon-package reference in [source]'s code, never in a
/// comment or string.
List<String> _rawIconReferences(String source) {
  final code = codeOnly(source);
  return [
    for (final pattern in [_lucideReference, ..._iconProviderReferences])
      for (final match in pattern.allMatches(code)) match.group(0)!,
  ];
}

void main() {
  test('nothing outside AppIcons references an icon package directly', () {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'run this from the design_system package root',
    );

    const appIconsFile = '../design_system/lib/src/app_icons.dart';
    final offenders = <String>[];
    for (final file in _clientSources()) {
      if (file.path == appIconsFile) continue;
      if (_exceptions.contains(file.path)) continue;
      for (final reference in _rawIconReferences(file.readAsStringSync())) {
        offenders.add('${file.path}: $reference');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'a raw icon-package reference was found outside AppIcons; add a '
          'named entry to AppIcons and reference that instead:\n'
          '${offenders.join('\n')}',
    );
  });

  test('a comment or string naming an icon is not a reference', () {
    expect(
        _rawIconReferences('/// Uses Icons.close and LucideIcons.x.'), isEmpty);
    expect(_rawIconReferences("final s = 'CupertinoIcons.heart';"), isEmpty);
    expect(_rawIconReferences('Icon(Icons.close)'), ['Icons.close']);
    expect(_rawIconReferences('Icon(LucideIcons.x)'), ['LucideIcons.x']);
  });

  /// The regex-level regression for the `CupertinoIcons` and `IconData`
  /// gaps: reverting either pattern in [_iconProviderReferences] fails
  /// exactly this test, since the file-scan test above only fails when the
  /// real tree carries an offender, and this tree carries none right now.
  test(
      'the material pattern list reaches Icons, CupertinoIcons and a bare '
      'IconData alike, and never AppIcons', () {
    bool matchesAny(String source) =>
        _iconProviderReferences.any((p) => p.hasMatch(source));

    expect(matchesAny('Icon(Icons.close)'), isTrue);
    expect(matchesAny('Icon(CupertinoIcons.heart)'), isTrue);
    expect(
      matchesAny("IconData(0xe5cd, fontFamily: 'MaterialIcons')"),
      isTrue,
      reason: 'a codepoint reaches the identical glyph with neither name in '
          'the source text',
    );
    expect(
      matchesAny('AppIcons.close'),
      isFalse,
      reason: 'must never fire on the vocabulary it exists to allow',
    );
  });
}
