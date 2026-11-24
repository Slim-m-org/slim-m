// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file outside the api package that reads the session's tokens must
/// wait for the trust gate before its first read, so the identity check
/// (decision 0036) cannot be skipped by a player or a socket that builds its
/// own request.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

/// Spotify's own tokens share the names; they never reach a slim-m server.
const _exempt = ['lib/src/spotify/'];

/// The same token pattern as the api package's twin, `trust_gate_coverage_test.dart`.
final _readsToken = RegExp(r'\b(accessToken|refreshToken)\b');
final _awaitsGate = RegExp(r'\bawait\s+[\w.?!()]*\bawaitTrust\s*\(');

/// Why [source] reads a token without having waited for the gate first, or null when it does not.
String? trustGateProblem(String source) {
  final code = codeOnly(source);
  final read = _readsToken.firstMatch(code);
  if (read == null) return null;
  final gate = _awaitsGate.firstMatch(code);
  if (gate == null) return 'reads a token and never awaits awaitTrust()';
  return gate.start > read.start
      ? 'reads a token before awaiting awaitTrust()'
      : null;
}

void main() {
  test('every file that reads the session tokens awaits the gate first', () {
    final offenders = <String, String>{};
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final path = file.path.replaceAll(r'\', '/');
      if (_exempt.any(path.startsWith)) continue;
      if (trustGateProblem(file.readAsStringSync()) case final problem?) {
        offenders[path] = problem;
      }
    }
    expect(offenders, isEmpty);
  });

  test('the gate sees the video sources that read the token', () {
    final readers = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            _readsToken.hasMatch(codeOnly(file.readAsStringSync())))
          file.uri.pathSegments.last,
    ];
    expect(
      readers,
      containsAll([
        'attachment_video_source_io.dart',
        'attachment_video_source_web.dart',
      ]),
    );
  });

  group('the check itself', () {
    test('catches every spelling of a token read', () {
      for (final read in [
        'final t = api.session.tokens; send(t!.accessToken);',
        'send(api.session.tokens!.accessToken);',
        'final TokenPair(:accessToken) = api.session.tokens!;',
        'refresh(api.session.tokens?.refreshToken);',
      ]) {
        expect(trustGateProblem('void f() { $read }'), isNotNull, reason: read);
      }
    });

    test('a gate awaited after the read does not count', () {
      expect(
        trustGateProblem(
          'Future<void> f() async { final t = s.tokens?.accessToken; '
          'await api.awaitTrust(); send(t); }',
        ),
        isNotNull,
      );
    });

    test('a gate named only in a comment or a string does not count', () {
      expect(
        trustGateProblem(
          "Future<void> f() async { // await api.awaitTrust();\n"
          "log('await api.awaitTrust()'); send(s.tokens?.accessToken); }",
        ),
        isNotNull,
      );
    });

    test('a gate awaited before the first read passes', () {
      expect(
        trustGateProblem(
          'Future<void> f() async { await api.awaitTrust(); '
          'send(api.session.tokens?.accessToken); }',
        ),
        isNull,
      );
    });
  });
}
