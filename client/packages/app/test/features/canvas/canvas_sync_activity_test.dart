// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `CanvasSync`'s two hooks the activity log rides on: `onOpApplied` fires
/// for every op the catch-up feed actually applies, and `onHardReset` fires
/// when a reset discards local state - both are what let the accessibility
/// log see the same history a reconnect replays, not only what arrives live.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

Map<String, dynamic> _object(String id, {int seq = 1}) => {
  'id': id,
  'kind': 'stroke',
  'z_index': seq,
  'x': 0.0,
  'y': 0.0,
  'w': 10.0,
  'h': 10.0,
  'props': {
    'points': [0.0, 0.0, 10.0, 10.0],
  },
  'author_id': 'me',
  'seq': seq,
  'created_at': 0,
};

Map<String, dynamic> _rawOp(
  int seq,
  String kind, {
  Map<String, dynamic> extra = const {},
}) => {
  'seq': seq,
  'id': 'op-$seq',
  'actor_id': 'me',
  'created_at': 0,
  'kind': kind,
  ...extra,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

api.SlimmApi _fakeApi(http.Response Function(int afterSeq) onOpsRequest) =>
    testApi(
      (request) async {
        if (!request.url.path.endsWith('/canvas/ops')) return _json(<Object>[]);
        final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
        return onOpsRequest(afterSeq);
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

void main() {
  test('onOpApplied fires once per applied op, in order, and never for a '
      'place that named no live object', () async {
    final applied = <api.CanvasOp>[];
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c1',
      client: _fakeApi(
        (afterSeq) => _json({
          'ops': [
            _rawOp(1, 'place', extra: {'object': _object('a')}),
            _rawOp(
              2,
              'remove',
              extra: {
                'object_ids': ['a'],
              },
            ),
          ],
          'latest_seq': 2,
          'has_more': false,
          'reset': false,
        }),
      ),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
      onOpApplied: applied.add,
    );

    sync.seedFromViewport(0);
    await sync.catchUp();

    expect(applied.map((op) => op.seq), [1, 2]);
    expect(applied[0], isA<api.CanvasPlaceOp>());
    expect(applied[1], isA<api.CanvasRemoveOp>());
  });

  test('onOpApplied never fires for an unknown op kind - it triggers a reset '
      'instead', () async {
    final applied = <api.CanvasOp>[];
    var resets = 0;
    final document = CanvasDocument();
    final sync = CanvasSync(
      channelId: 'c1',
      client: _fakeApi(
        (afterSeq) => _json({
          'ops': [_rawOp(1, 'from-the-future')],
          'latest_seq': 1,
          'has_more': false,
          'reset': false,
        }),
      ),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
      onOpApplied: applied.add,
      onHardReset: () => resets++,
    );

    sync.seedFromViewport(0);
    await sync.catchUp();

    expect(applied, isEmpty);
    expect(resets, 1);
  });

  test(
    'onHardReset fires when the server reports the cursor unreachable',
    () async {
      var resets = 0;
      final document = CanvasDocument();
      final sync = CanvasSync(
        channelId: 'c1',
        client: _fakeApi(
          (afterSeq) => _json({
            'ops': <Object>[],
            'latest_seq': 0,
            'has_more': false,
            'reset': true,
          }),
        ),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
        onHardReset: () => resets++,
      );

      sync.seedFromViewport(5);
      await sync.catchUp();

      expect(resets, 1);
    },
  );
}
