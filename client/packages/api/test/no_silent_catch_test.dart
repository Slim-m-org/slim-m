// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failure the client catches must reach the log, so no catch clause or
/// `catchError` handler in `client/packages/*/lib` may have an empty body, no
/// catch-all may drop its error without logging or rethrowing it, and
/// production code logs through `AppLog` rather than `debugPrint`.
///
/// Reads code with comments and strings blanked ([codeOnly]), so a comment or
/// a string that merely contains the pattern neither hides nor fakes a hit.
/// A deliberate swallow still has a body: `AppLog.swallowed(tag, reason, ...)`.
library;

import 'dart:io';

import 'package:slimm_test_support/source_gates.dart';
import 'package:test/test.dart';

final _emptyCatch = RegExp(r'\bcatch\s*\([^)]*\)\s*\{\s*\}');
final _emptyOn = RegExp(r'\}\s*on\s+[\w.<>?]+\s*\{\s*\}');
final _emptyCatchError = RegExp(r'catchError\(\s*\([^)]*\)\s*\{\s*\}');

/// `=> null` and its kin: an empty body in an arrow.
final _arrowCatchError = RegExp(
  r'catchError\(\s*\([^)]*\)\s*=>\s*(null|false|true|0|const\b)',
);

/// A catch-all that binds no error: `catch (_)`, or `on Object` without `catch`.
/// One that names the error can hand it on, so only the dropped one is judged.
final _droppedCatchAll = RegExp(
  r'\bcatch\s*\(\s*_+\s*(?:,\s*_+\s*)?\)\s*\{'
  r'|\}\s*on\s+(?:Object\??|Exception|dynamic)\s*\{',
);

/// What lets a dropped catch-all stand: it logs, or it does not stop the failure.
final _reportsFailure = RegExp(
  r'\b(?:AppLog|reportFailure|reportFailureSentence|ignoreError|rethrow|throw|'
  r'throwWithStackTrace)\b',
);
final _debugPrint = RegExp(r'\bdebugPrint\s*\(');

/// The 1-based lines of every [_droppedCatchAll] in [code] whose body reports nothing.
List<int> silentCatchAlls(String code) {
  final lines = <int>[];
  for (final clause in _droppedCatchAll.allMatches(code)) {
    var depth = 1;
    var end = clause.end;
    while (depth > 0 && end < code.length) {
      depth += switch (code[end]) {
        '{' => 1,
        '}' => -1,
        _ => 0,
      };
      end++;
    }
    final body = code.substring(clause.end, end);
    if (!_reportsFailure.hasMatch(body)) {
      lines.add('\n'.allMatches(code.substring(0, clause.start)).length + 1);
    }
  }
  return lines;
}

/// The logger may echo to the console, and the voice harness's stdout is what the harness reads.
const _debugPrintAllowed = {
  'client/packages/app/lib/src/diagnostics/debug_log.dart',
  'client/packages/app/lib/src/diagnostics/voice_harness.dart',
  'client/packages/app/lib/src/diagnostics/voice_harness_media.dart',
};

void main() {
  final root = findRepoRoot();
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

  test('the catch-all pattern flags a dropped error and spares a reported one',
      () {
    for (final silent in [
      'try {} catch (_) { return null; }',
      'try {} catch (_, __) { return false; }',
      'try {} on Object {\n  return;\n}',
      'try {} on Exception { value = 1; }',
      'try {} catch (_) { /* AppLog.swallowed */ return null; }',
      "try {} catch (_) { return 'AppLog'; }",
    ]) {
      expect(silentCatchAlls(codeOnly(silent)), [1], reason: silent);
    }
    for (final reported in [
      'try {} catch (_) { AppLog.swallowed(t, r, e); return null; }',
      'try {} on Object { reportFailure(t, w, e); }',
      'try {} catch (_) { rethrow; }',
      'try {} on Object { throw StateError(\'x\'); }',
      'try {} on Object catch (e) { return e; }',
      'try {} on StateError { return null; }',
      'try {} catch (_) { if (x) { AppLog.swallowed(t, r, e); } }',
    ]) {
      expect(silentCatchAlls(codeOnly(reported)), isEmpty, reason: reported);
    }
  });

  test('no catch-all drops its error without logging it', () {
    final hits = <String>[];
    for (final file in files) {
      for (final line in silentCatchAlls(codeOnly(file.readAsStringSync()))) {
        hits.add('${relative(file)}:$line');
      }
    }
    expect(
      hits,
      isEmpty,
      reason: 'bind the error and log it: AppLog.swallowed(tag, reason, error, '
          'stack) keeps the fallback and leaves a trace (docs/error-handling.md)',
    );
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
