// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live frame that lands while a catch-up is in flight, and is newer than
/// the page that catch-up was answered from, must not be left unapplied.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_convergence_model.dart';
import 'support/canvas_convergence_wire.dart';

void main() {
  test('a live op newer than an in-flight catch-up page is not lost', () async {
    final log = <CanonOp>[
      for (var seq = 1; seq <= 7; seq++) CanonPlace(seq, 'o$seq', 0, 0, 1, 1),
    ];
    final firstPage = Completer<void>();
    var served = 0;
    final client = testApi(
      (request) async {
        if (!request.url.path.endsWith('/canvas/ops')) {
          return jsonResponse(<Object>[]);
        }
        final after = int.parse(request.url.queryParameters['after_seq']!);
        served++;
        if (served == 1) await firstPage.future;
        // The first answer is a snapshot of the server at seq 6.
        final head = served == 1 ? 6 : 7;
        final ops = log.where((o) => o.seq > after && o.seq <= head);
        return jsonResponse({
          'ops': ops.map(wireOp).toList(),
          'latest_seq': head,
          'has_more': false,
          'reset': false,
        });
      },
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c',
      client: client,
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    )..seedFromViewport(0);

    final inFlight = sync.catchUp();
    await Future<void>.delayed(Duration.zero);
    // Op 7 is broadcast live while the catch-up is still waiting on its page.
    sync.applyLive(7, () {});
    firstPage.complete();
    await inFlight;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(sync.asOfSeq, 7, reason: 'op 7 was dropped and nothing re-asks');
  });
}
