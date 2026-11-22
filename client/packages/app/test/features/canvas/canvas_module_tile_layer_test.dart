// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module tile on the canvas: its scene fills the tile's box wherever the
/// camera puts it, a frame from another viewer replaces it, a press goes to
/// the tile's own route, and a tile whose module is gone shows why.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_module_tiles.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_object_inputs.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_module_tile_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_module_tile_scope.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../module_scene_fixtures.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _scene(String status) => jsonEncode({
  ...sceneOf(4, 3, [
    {
      'op': 'rect',
      'x': 0,
      'y': 0,
      'w': 4,
      'h': 3,
      'fill': 'accent',
      'tap': 'hit',
    },
  ]),
  'status': status,
  'state': status,
  'live': true,
});

api.CanvasObject _tileObject(String id, Rect world, {String tile = 'Board'}) =>
    api.CanvasObject(
      id: id,
      kind: api.canvasModuleTileKind,
      zIndex: 1,
      x: world.left,
      y: world.top,
      w: world.width,
      h: world.height,
      props: {'module_id': 'board', 'tile': tile},
      authorId: 'me',
      seq: 1,
      createdAt: 0,
    );

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  final events = StreamController<api.ServerEvent>.broadcast();
  final presses = <String>[];
  final document = CanvasDocument()..setViewport(const Size(800, 600));

  ProviderContainer container() => ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/channels/c1/canvas/objects/gone/scene') {
          return _json({'error': 'its module is not installed'}, 409);
        }
        if (path.endsWith('/scene') && request.method == 'POST') {
          presses.add(request.body);
          return _json({'ok': true, 'output': _scene('pressed')});
        }
        if (path.endsWith('/scene')) {
          return _json({
            'object_id': request.url.pathSegments[4],
            'output': _scene('turn 1'),
            'ran_at': 1,
          });
        }
        return _json(<Object>[]);
      }),
    ],
  );

  void place(api.CanvasObject object) {
    document
      ..applyPlaced(canvasStrokeInputFrom(object)!)
      ..refresh();
  }
}

Future<void> _pump(WidgetTester tester, _Rig rig, ProviderContainer c) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: CanvasModuleTileScope(
            channelId: 'c1',
            onPlace: null,
            child: Stack(
              children: [CanvasModuleTileLayer(document: rig.document)],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Rect _tileRect(WidgetTester tester, String tile) =>
    tester.getRect(find.bySemanticsLabel(RegExp('^$tile, a module tile')));

void _expectInside(Rect inner, Rect outer) {
  expect(outer.contains(inner.topLeft), isTrue, reason: '$inner in $outer');
  expect(
    outer.inflate(0.5).contains(inner.bottomRight),
    isTrue,
    reason: '$inner in $outer',
  );
}

void main() {
  testWidgets('the tile fills its world box as the camera places it', (
    tester,
  ) async {
    final rig = _Rig();
    final c = rig.container();
    addTearDown(c.dispose);
    addTearDown(rig.events.close);
    rig.document.setCamera(const Camera(x: -100, y: -50, zoom: 0.5));
    rig.place(_tileObject('t1', const Rect.fromLTWH(200, 100, 640, 480)));
    await _pump(tester, rig, c);

    final rect = _tileRect(tester, 'Board');
    expect(rect.left, moreOrLessEquals((200 + 100) * 0.5));
    expect(rect.top, moreOrLessEquals((100 + 50) * 0.5));
    expect(rect.width, moreOrLessEquals(640 * 0.5));
    expect(rect.height, moreOrLessEquals(480 * 0.5));
    _expectInside(tester.getRect(find.text('turn 1')), rect);

    rig.document
      ..setCamera(const Camera(zoom: 1))
      ..refresh();
    await tester.pump();
    final zoomed = _tileRect(tester, 'Board');
    expect(zoomed, const Rect.fromLTWH(200, 100, 640, 480));
  });

  testWidgets('a frame another viewer stored replaces the scene', (
    tester,
  ) async {
    final rig = _Rig();
    final c = rig.container();
    addTearDown(c.dispose);
    addTearDown(rig.events.close);
    rig.document.setCamera(const Camera(zoom: 1));
    rig.place(_tileObject('t1', const Rect.fromLTWH(20, 20, 400, 300)));
    await _pump(tester, rig, c);
    expect(find.text('turn 1'), findsOneWidget);

    rig.events.add(
      api.CanvasTileSceneChanged(
        channelId: 'other',
        objectId: 't1',
        output: _scene('elsewhere'),
        ranAt: 2,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('turn 1'), findsOneWidget, reason: 'another canvas');

    rig.events.add(
      api.CanvasTileSceneChanged(
        channelId: 'c1',
        objectId: 't1',
        output: _scene('turn 2'),
        ranAt: 3,
      ),
    );
    await tester.pump();
    await tester.pump();
    _expectInside(
      tester.getRect(find.text('turn 2')),
      _tileRect(tester, 'Board'),
    );
  });

  testWidgets('a press goes to the tile route, and not while it is selected', (
    tester,
  ) async {
    final rig = _Rig();
    final c = rig.container();
    addTearDown(c.dispose);
    addTearDown(rig.events.close);
    rig.document.setCamera(const Camera(zoom: 1));
    rig.place(_tileObject('t1', const Rect.fromLTWH(20, 20, 400, 300)));
    await _pump(tester, rig, c);

    final center = _tileRect(tester, 'Board').center;
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(rig.presses, hasLength(1));
    expect(jsonDecode(rig.presses.single)['input'], contains('hit'));

    rig.document.selectedObjectId.value = 't1';
    await tester.pump();
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    expect(rig.presses, hasLength(1), reason: 'a selected tile is the board');
  });

  testWidgets('a tile whose module is gone shows why inside its box', (
    tester,
  ) async {
    final rig = _Rig();
    final c = rig.container();
    addTearDown(c.dispose);
    addTearDown(rig.events.close);
    rig.document.setCamera(const Camera(zoom: 1));
    rig.place(
      _tileObject('gone', const Rect.fromLTWH(40, 40, 480, 360), tile: 'Dice'),
    );
    await _pump(tester, rig, c);
    await tester.pump();

    final message = find.textContaining('not installed');
    expect(message, findsOneWidget);
    _expectInside(tester.getRect(message), _tileRect(tester, 'Dice'));
  });

  test(
    'a module object becomes a tile, and anything unreadable is left out',
    () {
      final input = canvasStrokeInputFrom(
        _tileObject('t1', const Rect.fromLTWH(0, 0, 10, 10)),
      );
      expect(input?.kind, CanvasObjectKind.tile);
      expect(input?.tileKey, 'module:board/Board');
      expect(ModuleTileRef.fromKey('watch:board/Board'), isNull);

      api.CanvasObject withProps(String kind, Map<String, dynamic> props) =>
          api.CanvasObject(
            id: 'x',
            kind: kind,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 10,
            h: 10,
            props: props,
            authorId: null,
            seq: 1,
            createdAt: 0,
          );
      expect(
        canvasStrokeInputFrom(withProps('module', {'tile': 'Board'})),
        isNull,
      );
      expect(
        canvasStrokeInputFrom(
          withProps('module', {'module_id': 'a/b', 'tile': 'T'}),
        ),
        isNull,
      );
      expect(canvasStrokeInputFrom(withProps('hologram', {'x': 1})), isNull);
    },
  );
}
