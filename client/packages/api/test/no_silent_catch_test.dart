// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failure the client catches must reach the log, so no catch clause or
/// `catchError` handler in `client/packages/*/lib` may have an empty body, and
/// production code logs through `AppLog` rather than `debugPrint`.
///
/// Reads code with comments and strings blanked ([codeOnly]), so a comment or
/// a string that merely contains the pattern neither hides nor fakes a hit.
/// A deliberate swallow still has a body: `AppLog.swallowed(tag, reason, ...)`.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/code_only.dart';

final _emptyCatch = RegExp(r'\bcatch\s*\([^)]*\)\s*\{\s*\}');
final _emptyOn = RegExp(r'\}\s*on\s+[\w.<>?]+\s*\{\s*\}');
final _emptyCatchError = RegExp(r'catchError\(\s*\([^)]*\)\s*\{\s*\}');

/// `=> null` and its kin: an empty body in an arrow.
final _arrowCatchError = RegExp(
  r'catchError\(\s*\([^)]*\)\s*=>\s*(null|false|true|0|const\b)',
);
final _debugPrint = RegExp(r'\bdebugPrint\s*\(');

/// The logger may echo to the console, and the voice harness's stdout is what the harness reads.
const _debugPrintAllowed = {
  'client/packages/app/lib/src/diagnostics/debug_log.dart',
  'client/packages/app/lib/src/diagnostics/voice_harness.dart',
};

void main() {
  final root = _repoRoot();
  final files = [
    for (final package in Directory('${root.path}/client/packages').listSync())
      if (package is Directory && Directory('${package.path}/lib').existsSync())
        ...Directory('${package.path}/lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
  ];

  String relative(File f) => f.path.substring(root.path.length + 1);

  test('the scan reads the client sources', () {
    expect(files.length, greaterThan(500));
  });

  test('the patterns catch the shapes they exist for', () {
    for (final bad in [
      'try {} catch (_) {}',
      'try {} catch (e, s) {\n}',
      'try {} on StateError {}',
      'f.catchError((_) {})',
      'f.catchError((_) => null)',
    ]) {
      final code = codeOnly(bad);
      expect(
        _emptyCatch.hasMatch(code) ||
            _emptyOn.hasMatch(code) ||
            _emptyCatchError.hasMatch(code) ||
            _arrowCatchError.hasMatch(code),
        isTrue,
        reason: bad,
      );
    }
    final commented = codeOnly("try {} catch (_) { /* x */ } // catch (_) {}");
    expect(_emptyCatch.hasMatch(commented), isTrue, reason: 'comment only');
    expect(_emptyCatch.hasMatch(codeOnly("'catch (_) {}'")), isFalse);
  });

  test('no catch clause or catchError handler has an empty body', () {
    final hits = <String>[];
    for (final file in files) {
      final code = codeOnly(file.readAsStringSync());
      for (final pattern in [
        _emptyCatch,
        _emptyOn,
        _emptyCatchError,
        _arrowCatchError,
      ]) {
        for (final m in pattern.allMatches(code)) {
          final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
          hits.add('${relative(file)}:$line');
        }
      }
    }
    expect(
      hits,
      isEmpty,
      reason: 'log it instead: AppLog.swallowed(tag, reason, error, stack) for '
          'a deliberate swallow, reportFailure for a real failure '
          '(docs/error-handling.md)',
    );
  });

  test('production code logs through AppLog, not debugPrint', () {
    final hits = <String>[];
    for (final file in files) {
      if (_debugPrintAllowed.contains(relative(file))) continue;
      final code = codeOnly(file.readAsStringSync());
      for (final m in _debugPrint.allMatches(code)) {
        final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
        hits.add('${relative(file)}:$line');
      }
    }
    expect(hits, isEmpty);
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
