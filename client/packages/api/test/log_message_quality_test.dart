// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A log message has to say what happened in words a user or maintainer can
/// act on, so it may not point at code, repeat its own tag, or be a leftover
/// of a generated name such as "set state failed, ignored".
///
/// Reads code with comments stripped ([stripComments]) so a commented-out
/// call does not count, and the message text itself stays intact.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/code_only.dart';

final _call = RegExp(
  r"(?:AppLog\.(?:debug|info|warning|error|swallowed)|reportFailure|ignoreError)"
  r"\(\s*(?:'[^']*'|[\w.]+)\s*,\s*"
  r"((?:'(?:[^'\\]|\\.)*'(?:\s*'(?:[^'\\]|\\.)*')*)|(?:\x22[^\x22]*\x22))",
  dotAll: true,
);

final _tags = [
  'sync', 'push', 'voice', 'auth', 'media', 'data', 'platform', 'ui', 'net', //
];

/// Phrases that send the reader to the source instead of saying anything.
final _codeReference = RegExp(
  r"doc comment|\bdoc\b|class doc|own doc|see (the |this |that )?"
  r"(class|above|below|comment|function|method|source|code)|see [A-Z]\w+'s|"
  r"failed, ignored|\bset state\b",
  caseSensitive: false,
);

String _text(String literal) => literal
    .replaceAll(RegExp(r"""['"]\s*['"]"""), '')
    .replaceFirst(RegExp(r"""^['"]"""), '')
    .replaceFirst(RegExp(r"""['"]$"""), '');

List<String> problems(String source) {
  final out = <String>[];
  for (final m in _call.allMatches(stripComments(source))) {
    final text = _text(m.group(1)!);
    final tagPrefix = RegExp(
      '^(${_tags.join('|')}):',
      caseSensitive: false,
    );
    if (_codeReference.hasMatch(text)) {
      out.add('refers to code or a generated name: "$text"');
    } else if (tagPrefix.hasMatch(text)) {
      out.add('repeats its own tag: "$text"');
    } else if (text.startsWith(RegExp('could not ', caseSensitive: false)) &&
        m.group(0)!.contains('reportFailure')) {
      out.add('reportFailure adds "Could not" itself: "$text"');
    }
  }
  return out;
}

void main() {
  test('the check flags code references, tag echoes and generated names', () {
    expect(problems("AppLog.swallowed(LogTag.ui, 'see the class doc', e);"),
        isNotEmpty);
    expect(
        problems("AppLog.swallowed(LogTag.ui, 'Best-effort: see the doc "
            "comment above', e);"),
        isNotEmpty);
    expect(
        problems(
            "AppLog.swallowed(LogTag.ui, 'set state failed, ignored', e);"),
        isNotEmpty);
    expect(
        problems("AppLog.info(LogTag.voice, 'voice: Strong on');"), isNotEmpty);
    expect(problems("reportFailure(LogTag.ui, 'Could not save', e, s);"),
        isNotEmpty);
  });

  test('plain messages and commented-out calls pass', () {
    expect(
        problems("AppLog.warning(LogTag.auth, 'Could not read the saved "
            "session; staying signed out');"),
        isEmpty);
    expect(
        problems("// AppLog.swallowed(LogTag.ui, 'see above', e);"), isEmpty);
  });

  test('every log message in the client reads as a plain sentence', () {
    final root = _repoRoot();
    final hits = <String>[];
    for (final package
        in Directory('${root.path}/client/packages').listSync()) {
      final lib = Directory('${package.path}/lib');
      if (!lib.existsSync()) continue;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        for (final p in problems(file.readAsStringSync())) {
          hits.add('${file.path.substring(root.path.length + 1)}: $p');
        }
      }
    }
    expect(hits, isEmpty, reason: 'say what happened; docs/error-handling.md');
  });
}

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    dir = dir.parent;
  }
  fail('could not find the repo root from ${Directory.current.path}');
}
