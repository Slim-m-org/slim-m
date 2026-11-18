// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A timeout that runs out on its own brings the composer back. The server
/// sends nothing then, so the channel's permissions, fetched while Send was
/// withheld, must be fetched again rather than read as a read-only channel.
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/composer/widgets/composer_read_only_bar.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../channel_history_harness.dart';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('the composer comes back when a timeout runs out', (
    tester,
  ) async {
    final until = clock
        .now()
        .add(const Duration(minutes: 1))
        .millisecondsSinceEpoch;
    bool timedOut() => clock.now().millisecondsSinceEpoch < until;
    await mountChannel(
      tester,
      serverSeqs: const [1],
      seededSeqs: const [1],
      answerFirst: (request) async {
        switch (request.url.path) {
          case '/me':
            return _json({
              'id': 'bob',
              'username': 'bob',
              'display_name': 'Bob',
              'created_at': 0,
              'permissions': 0,
              if (timedOut()) 'timed_out_until': until,
            });
          case '/channels/c1/permissions':
            final bits = timedOut()
                ? Perm.viewChannel
                : Perm.viewChannel | Perm.sendMessages;
            // Lands after me, the order that would show the stale bits for a moment.
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return _json({'permissions': bits});
        }
        return null;
      },
    );
    final banner = find.textContaining('You are timed out');
    final readOnly = find.text(ComposerReadOnlyBar.message);
    final sendBar = find.byKey(const Key('composer-action-bar'));
    expect(banner, findsOneWidget);
    expect(readOnly, findsNothing);

    await tester.pump(const Duration(minutes: 1));
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(readOnly, findsNothing, reason: 'frame $frame');
    }

    expect(banner, findsNothing);
    expect(sendBar.hitTestable(), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });
}
