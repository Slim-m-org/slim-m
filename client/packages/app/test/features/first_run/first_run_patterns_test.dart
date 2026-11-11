// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile step's generated avatars: stable per account, different across
/// accounts, and uploaded as a real picture.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/first_run/widgets/avatar_patterns.dart';

import '../../support/async_wait.dart';
import 'first_run_harness.dart';

const _base = Color(0xFF1A6E94);

http.Response? _accept(http.Request r) {
  if (r.url.path != '/me/avatar') return null;
  if (r.method == 'DELETE') return http.Response('', 204);
  return http.Response(
    jsonEncode({
      'id': 'u1',
      'username': 'ada',
      'display_name': 'Ada',
      'created_at': 0,
      'avatar_updated_at': 5,
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<FirstRunRig> _toProfile(
  WidgetTester tester, {
  http.Response? Function(http.Request)? respond,
}) async {
  final rig = await pumpFirstRun(
    tester,
    size: const Size(390, 900),
    respond: respond ?? _accept,
  );
  await tester.tap(find.text('Continue'));
  await settle(tester);
  return rig;
}

void main() {
  test('a seed is stable for an id and differs between ids', () {
    expect(patternSeed('user-a'), patternSeed('user-a'));
    expect(patternSeed('user-a'), isNot(patternSeed('user-b')));
    expect(
      patternPalette(_base, patternSeed('user-a')),
      patternPalette(_base, patternSeed('user-a')),
    );
    expect(
      patternPalette(_base, patternSeed('user-a')),
      isNot(patternPalette(_base, patternSeed('user-b'))),
    );
  });

  testWidgets('the same account renders the same bytes, another does not', (
    tester,
  ) async {
    final (a1, a2, b) = (await tester.runAsync(() async {
      Future<Uint8List> render(String id) =>
          renderPatternPng(AvatarPattern.marble, accountId: id, base: _base);
      return (
        await render('user-a'),
        await render('user-a'),
        await render('user-b'),
      );
    }))!;
    expect(a1, a2);
    expect(a1, isNot(b));
    expect(a1.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
  });

  testWidgets('picking a pattern uploads a PNG as the avatar', (tester) async {
    final rig = await _toProfile(tester);
    expect(find.text('Or pick a pattern'), findsOneWidget);
    for (final pattern in AvatarPattern.values) {
      expect(
        find.bySemanticsLabel('Use the ${pattern.name} pattern'),
        findsOneWidget,
      );
    }

    await tester.tap(find.bySemanticsLabel('Use the rings pattern'));
    await waitUntil(tester, () => rig.sent('POST', '/me/avatar').isNotEmpty);

    final body = rig.sent('POST', '/me/avatar').single.bodyBytes;
    expect(body.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
  });

  testWidgets('keeping the initials removes any picture', (tester) async {
    final rig = await _toProfile(tester);
    await tester.tap(find.bySemanticsLabel('Use my initials'));
    await waitUntil(tester, () => rig.sent('DELETE', '/me/avatar').isNotEmpty);
    expect(rig.sent('POST', '/me/avatar'), isEmpty);
  });

  testWidgets('a failed upload says so and offers a retry', (tester) async {
    var failing = true;
    final rig = await _toProfile(
      tester,
      respond: (r) =>
          r.method == 'POST' && r.url.path == '/me/avatar' && failing
          ? http.Response('{"error":"boom"}', 500)
          : _accept(r),
    );
    await tester.tap(find.bySemanticsLabel('Use the beams pattern'));
    await waitUntil(tester, () => rig.sent('POST', '/me/avatar').isNotEmpty);

    expect(find.textContaining('Could not set your picture'), findsOneWidget);
    failing = false;
    await tester.ensureVisible(find.text('Retry'));
    await tester.pump();
    await tester.tap(find.text('Retry'));
    await waitUntil(tester, () => rig.sent('POST', '/me/avatar').length == 2);
    expect(find.text('Retry'), findsNothing);
  });
}
