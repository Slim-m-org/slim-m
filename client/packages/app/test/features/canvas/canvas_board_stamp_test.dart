// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stamp on the board (decision 0121) is an ordinary item that stays: an
/// emoji is the `emoji` kind with its reaction key, a picture is an `image`,
/// and every stamp of one emoji paints from one baked bitmap.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_object_inputs.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_emoji_hydrator.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_quick_placement.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_stamp_placement.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.CanvasObject _object(String id, String kind, Map<String, dynamic> props) =>
    api.CanvasObject.fromJson({
      'id': id,
      'kind': kind,
      'z_index': 1,
      'x': 100.0,
      'y': 100.0,
      'w': 130.0,
      'h': 130.0,
      'props': props,
      'author_id': 'me',
      'seq': 1,
      'created_at': 0,
    });

api.SlimmApi _client(List<Map<String, dynamic>> posted) => api.SlimmApi(
  baseUrl: Uri.parse('http://test.invalid'),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 4102444800000,
    ),
  ),
  httpClient: MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    posted.add(body);
    return http.Response(
      jsonEncode({
        ...body,
        'z_index': 1,
        'author_id': 'me',
        'seq': 1,
        'created_at': 0,
      }),
      201,
      headers: {'content-type': 'application/json'},
    );
  }),
);

Future<ui.Image> _bitmap() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const ui.Color(0xFFE8B04B),
  );
  return recorder.endRecording().toImage(8, 8);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the wire', () {
    test('an emoji object carries its key', () {
      final input = canvasStrokeInputFrom(
        _object('e1', 'emoji', {'emoji': '\u{1F389}'}),
      )!;
      expect(input.kind, CanvasObjectKind.emoji);
      expect(input.text, '\u{1F389}');
    });

    test('an emoji object with no key, or the wrong type, is not drawn', () {
      expect(canvasStrokeInputFrom(_object('e1', 'emoji', {})), isNull);
      expect(
        canvasStrokeInputFrom(_object('e1', 'emoji', {'emoji': 7})),
        isNull,
      );
    });
  });

  group('placing', () {
    late List<Map<String, dynamic>> posted;
    late CanvasQuickPlacement placement;

    setUp(() {
      posted = [];
      placement = CanvasQuickPlacement(
        client: _client(posted),
        channelId: 'c',
        document: CanvasDocument()..setViewport(const Size(1200, 800)),
        timedOutUntil: () => null,
      );
    });

    test('an emoji is a square emoji item of the given side', () async {
      await placement.placeStamp(
        const Offset(300, 300),
        const EmojiStamp('\u{1F389}'),
        side: boardStampDefaultSide,
        onError: (_) {},
      );
      final body = posted.single;
      expect(body['kind'], 'emoji');
      expect(body['props'], {'emoji': '\u{1F389}'});
      expect((body['w'], body['h']), (130.0, 130.0));
    });

    test('a picture is an image item keeping its shape', () async {
      await placement.placeStamp(
        const Offset(300, 300),
        const PictureStamp('abc'),
        side: 300,
        aspect: 3,
        onError: (_) {},
      );
      final body = posted.single;
      expect(body['kind'], 'image');
      expect(body['props'], {'attachment': 'abc'});
      expect((body['w'], body['h']), (300.0, 100.0));
    });

    test('a tap uses the default side and a drag is held to the cap', () async {
      final sides = <double>[];
      final stamping = CanvasStampPlacement(
        placement: () => placement,
        armed: () => const EmojiStamp('\u{1F389}'),
        aspectOf: (_) => 1,
        onShown: () {},
        onError: (_) {},
      );
      addTearDown(stamping.dispose);
      await stamping.place(const Offset(0, 0), null);
      await stamping.place(const Offset(0, 0), 2000);
      await stamping.place(const Offset(0, 0), 1);
      for (final body in posted) {
        sides.add((body['w'] as num).toDouble());
      }
      expect(sides, [
        boardStampDefaultSide,
        boardStampMaxSide,
        boardStampMinSide,
      ]);
    });
  });

  group('baking', () {
    test('every stamp of one emoji paints from one bake', () async {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      addTearDown(document.dispose);
      for (final id in ['e1', 'e2']) {
        document.applyPlaced(
          canvasStrokeInputFrom(_object(id, 'emoji', {'emoji': 'x'}))!,
        );
      }
      document.refresh();
      var bakes = 0;
      final hydrator = CanvasEmojiHydrator(
        document: document,
        bake: (_) async {
          bakes++;
          return _bitmap();
        },
      );
      addTearDown(hydrator.dispose);
      hydrator.hydrateVisible();
      await pumpEventQueue();
      expect(bakes, 1);
      expect(document.visibleEmojiAwaitingBitmap, isEmpty);
    });

    test('an emoji that will not bake shows the missing placeholder', () async {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      addTearDown(document.dispose);
      final object = _object('e1', 'emoji', {'emoji': 'x'});
      document
        ..applyPlaced(canvasStrokeInputFrom(object)!)
        ..refresh();
      final hydrator = CanvasEmojiHydrator(
        document: document,
        bake: (_) async => null,
      );
      addTearDown(hydrator.dispose);
      hydrator.hydrate(object);
      await pumpEventQueue();
      expect(document.visibleEmojiAwaitingBitmap, isEmpty);
    });
  });
}
