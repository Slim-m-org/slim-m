// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the two suites that pump a [CanvasPane]: its fetch,
/// live-frame and drag behaviour (`canvas_pane_test.dart`) and its erase,
/// undo and clear controls (`canvas_pane_ops_test.dart`).
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because both suites need the same fake canvas API, the same
/// signed-in session and the same way to pump the pane, none of which
/// either suite is actually about.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class NoopSyncController extends SyncController {
  NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

const testTokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> canvasObjectJson(
  String id, {
  double x = 10,
  int seq = 1,
  String authorId = 'me',
}) => {
  'id': id,
  'kind': 'stroke',
  'z_index': seq,
  'x': x,
  'y': 10.0,
  'w': 20.0,
  'h': 20.0,
  'props': {
    'points': [0.0, 0.0, 20.0, 20.0],
    'width': 3.0,
    'color': 'annotation',
  },
  'author_id': authorId,
  'seq': seq,
  'created_at': 0,
};

Map<String, dynamic> canvasImageJson(
  String id, {
  double x = 10,
  int seq = 1,
  String authorId = 'me',
}) => {
  'id': id,
  'kind': 'image',
  'z_index': seq,
  'x': x,
  'y': 10.0,
  'w': 20.0,
  'h': 20.0,
  'props': {'attachment': 'sha-$id', 'content_type': 'image/png'},
  'author_id': authorId,
  'seq': seq,
  'created_at': 0,
};

Map<String, dynamic> canvasNoteJson(
  String id, {
  double x = 10,
  int seq = 1,
  String authorId = 'me',
  String text = 'a note',
}) => {
  'id': id,
  'kind': 'note',
  'z_index': seq,
  'x': x,
  'y': 10.0,
  'w': 20.0,
  'h': 20.0,
  'props': {'text': text},
  'author_id': authorId,
  'seq': seq,
  'created_at': 0,
};

/// A 1x1 transparent PNG: real bytes, so a hydration fetch decodes rather
/// than throwing. Public so other suites pumping a real canvas (rather than
/// this file's own fixture) can serve the identical bytes.
final canvasPngFixture = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class CanvasPaneFixture {
  CanvasPaneFixture({
    this.viewportStatus = 200,
    this.hasMore = false,
    this.mePermissions = 0,
    int? channelPermissions,
    this.opsPostStatus = 201,
    this.placeStatus = 201,
    this.attachmentFetchStatus = 200,
    this.attachmentUploadStatus = 200,
  }) : channelPermissions = channelPermissions ?? mePermissions;

  final StreamController<api.ServerEvent> events =
      StreamController<api.ServerEvent>.broadcast();

  final int viewportStatus;
  final bool hasMore;

  /// The status `POST .../canvas/ops` answers with, so a test can drive the
  /// controller's failure path (a revert) without a real server refusal.
  final int opsPostStatus;

  /// The status `POST .../canvas/objects` (a plain stroke, note, shape or
  /// image placement) answers with - the sibling of [opsPostStatus] for the
  /// `place` route rather than the op-stream one, so a test can drive a
  /// refused draw (403 forbidden, timeout freeze; 409 channel full) without
  /// a real server refusal.
  final int placeStatus;

  /// The status `GET .../attachments/{id}` answers with. 200 serves a real
  /// decodable PNG, so a test can prove an image object placed by anyone
  /// other than this client ends up hydrated; any other value drives the
  /// hydrator's own failure-placeholder path.
  final int attachmentFetchStatus;

  /// The status `POST /attachments` answers with, so a test can drive a refused
  /// upload (413 too big, 507 no storage) from a paste.
  final int attachmentUploadStatus;

  /// Every `GET .../attachments/{id}` the pane's image hydrator sent.
  int attachmentFetches = 0;

  /// The signed-in member's own permission bitmask, as `GET /me` answers it.
  final int mePermissions;

  /// What `GET /channels/{channelId}/permissions` answers - defaults to
  /// [mePermissions], but a test proving the per-channel gate (rather than
  /// the deployment-wide one) drives the canvas menu passes a different
  /// value here to make the two genuinely disagree.
  final int channelPermissions;
  final List<Map<String, dynamic>> posted = [];
  List<Map<String, dynamic>> objects = [];

  /// Every `GET .../canvas/objects` the pane sent, in order. A count rather
  /// than a bare int so a test can tell "one, twice as many as needed" from
  /// "the same fetch racing itself and never stopping".
  int viewportGets = 0;

  /// Every `GET .../canvas/ops` the pane sent: every viewport fetch runs a
  /// catch-up afterward, so this file's own tests only need the default
  /// answer below to keep paging correct - it is not itself under test here.
  int opsGets = 0;

  /// Every `POST .../canvas/ops` (remove, clear, restore) the pane sent.
  final List<Map<String, dynamic>> postedOps = [];
  var _opSeq = 0;

  /// A caller that also needs `voiceControllerProvider` or `blocksProvider`
  /// stubbed (the presence-layer suite) appends onto this rather than this
  /// fixture growing a case for every consumer's own needs.
  ProviderContainer container({
    List<Override> extraOverrides = const [],
  }) => ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: testTokens)),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/me')) {
              return jsonResponse({
                'id': 'me',
                'username': 'me',
                'display_name': 'Me',
                'created_at': 0,
                'permissions': mePermissions,
              });
            }
            if (request.url.path.endsWith('/permissions')) {
              return jsonResponse({'permissions': channelPermissions});
            }
            if (request.url.path.endsWith('/canvas/ops') &&
                request.method == 'POST') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if (opsPostStatus != 201) {
                return http.Response(
                  jsonEncode({'error': 'no'}),
                  opsPostStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              postedOps.add(body);
              _opSeq++;
              return http.Response(
                jsonEncode({
                  'op': {
                    'id': 'server-op-$_opSeq',
                    'seq': _opSeq,
                    'kind': body['kind'],
                    'affected': 1,
                    'created_at': 0,
                  },
                  'fresh': true,
                }),
                201,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path.endsWith('/canvas/ops')) {
              opsGets++;
              // Echoes the cursor back as the latest seq, so this fixture never answers `reset` or reports a gap.
              final afterSeq = int.parse(
                request.url.queryParameters['after_seq']!,
              );
              return jsonResponse({
                'ops': <Object>[],
                'latest_seq': afterSeq,
                'has_more': false,
                'reset': false,
              });
            }
            if (request.url.path.endsWith('/canvas/media-slots')) {
              return jsonResponse({'slots': <Object>[]});
            }
            if (request.url.path.endsWith('/canvas/object-locks')) {
              return jsonResponse({'object_ids': <Object>[]});
            }
            if (request.url.path.contains('/canvas/media-slots/')) {
              final segments = request.url.pathSegments;
              return jsonResponse({
                'kind': segments[segments.length - 2],
                'user_id': segments.last,
                'x': 0.0,
                'y': 0.0,
                'w': 1.0,
                'h': 1.0,
                'locked': false,
                'sent_to_back': false,
                'updated_at': 0,
              });
            }
            if (request.url.path == '/attachments' &&
                request.method == 'POST') {
              if (attachmentUploadStatus != 200) {
                return http.Response(
                  jsonEncode({'error': 'refused'}),
                  attachmentUploadStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              return jsonResponse({
                'id': 'sha-pasted',
                'filename': 'pasted-image.png',
                'content_type': 'image/png',
                'size': canvasPngFixture.length,
              });
            }
            if (request.url.path.startsWith('/attachments/')) {
              attachmentFetches++;
              if (attachmentFetchStatus != 200) {
                return http.Response(
                  jsonEncode({'error': 'no'}),
                  attachmentFetchStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response.bytes(
                canvasPngFixture,
                200,
                headers: {'content-type': 'image/png'},
              );
            }
            if (!request.url.path.endsWith('/canvas/objects')) {
              return jsonResponse(<Object>[]);
            }
            if (request.method == 'POST') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if (placeStatus != 201) {
                return http.Response(
                  jsonEncode({'error': 'no'}),
                  placeStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              posted.add(body);
              return http.Response(
                jsonEncode({
                  ...canvasObjectJson(body['id'] as String),
                  'kind': body['kind'],
                  'x': body['x'],
                  'y': body['y'],
                  'w': body['w'],
                  'h': body['h'],
                  'props': body['props'],
                }),
                201,
                headers: {'content-type': 'application/json'},
              );
            }
            viewportGets++;
            if (viewportStatus != 200) {
              return http.Response(
                jsonEncode({'error': 'no'}),
                viewportStatus,
                headers: {'content-type': 'application/json'},
              );
            }
            return jsonResponse({
              'objects': objects,
              'has_more': hasMore,
              'latest_seq': objects.length,
            });
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      ...extraOverrides,
    ],
  );
}

Future<void> pumpCanvasPane(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: CanvasPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

CanvasDocument surfaceDocument(WidgetTester tester) {
  final surface = tester.widget<CanvasSurface>(find.byType(CanvasSurface));
  return surface.document;
}

/// The screen point for a [world] coordinate, given the surface's default
/// camera (`Camera(x: 0, y: 0, zoom: 1)`, which nothing in either suite
/// moves): world and local surface coordinates coincide, so this only has
/// to add the surface's own on-screen origin.
Offset screenFor(WidgetTester tester, Offset world) =>
    tester.getTopLeft(find.byType(CanvasSurface)) + world;
