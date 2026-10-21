// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the `dispatchCanvasLiveEvent` suites.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_object_preview_relay.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

api.CanvasObject canvasStrokeObject(String id, {String? authorId = 'alice'}) =>
    api.CanvasObject(
      id: id,
      kind: 'stroke',
      zIndex: 1,
      x: 0,
      y: 0,
      w: 1,
      h: 1,
      props: const {},
      authorId: authorId,
      seq: 1,
      createdAt: 0,
    );

/// A client that never actually answers: every `dispatch` call below lands
/// on the first, adjacent seq, so `CanvasSync.applyLive` never needs to
/// fetch anything - `canvas_sync_test.dart` is the suite that drives a real
/// catch-up fetch.
api.SlimmApi inertCanvasApi() => testApi(
  (_) async => throw StateError('no request expected in this suite'),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    ),
  ),
);

/// A `CanvasSync` whose `applyLive` always runs the callback, for tests of the dispatch switch alone; seeded at [seededAt] since a sequenced frame before the first read is ignored.
CanvasSync inertCanvasSync(CanvasDocument document, {int seededAt = 0}) =>
    CanvasSync(
      channelId: 'c1',
      client: inertCanvasApi(),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    )..seedFromViewport(seededAt);

CanvasObjectPreviewRelay quietPreviewRelay(CanvasDocument document) =>
    CanvasObjectPreviewRelay(
      previews: RemoteObjectPreviews(document),
      send: (_, _, _) {},
      isBlocked: (_) => false,
      selfId: () => null,
      isDraggingLocally: (_) => false,
    );

class RecordingPreviewRelay extends CanvasObjectPreviewRelay {
  RecordingPreviewRelay(CanvasDocument document)
    : super(
        previews: RemoteObjectPreviews(document),
        send: (_, _, _) {},
        isBlocked: (_) => false,
        selfId: () => null,
        isDraggingLocally: (_) => false,
      );

  final applied = <(String, String, ObjectBox, bool)>[];
  final settled = <String>[];

  @override
  void applyRemote(String userId, String objectId, ObjectBox box, bool ended) =>
      applied.add((userId, objectId, box, ended));

  @override
  void settle(String objectId) => settled.add(objectId);
}

const canvasPreviewFrame = api.CanvasObjectPreview(
  channelId: 'c1',
  userId: 'alice',
  objectId: 'a',
  x: 1,
  y: 2,
  w: 3,
  h: 4,
  ended: false,
);

void placeCanvasImage(CanvasDocument document) => document.applyPlaced(
  const CanvasStrokeInput(
    id: 'a',
    seq: 1,
    zIndex: 1,
    x: 0,
    y: 0,
    w: 1,
    h: 1,
    points: [],
    width: 0,
    colorKey: '',
    kind: CanvasObjectKind.image,
  ),
);
