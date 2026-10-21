// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's personal canvas layout outlives closing the canvas and an app
/// restart, stays per channel, comes back inside the board, is given up to
/// following or a summon without being lost, and is never sent. Decision 0082.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_personal_layout_keeper.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/fake_api.dart';
import 'canvas_pane_harness.dart';

const _viewport = Size(1280, 720);
const _place = Rect.fromLTWH(900, 500, 360, 203);

Object _get(String path) {
  if (path.endsWith('/canvas/media-slots')) return {'slots': <Object>[]};
  if (path.endsWith('/canvas/object-locks')) return {'object_ids': <Object>[]};
  if (path.endsWith('/canvas/ops')) {
    return {
      'ops': <Object>[],
      'latest_seq': 0,
      'has_more': false,
      'reset': false,
    };
  }
  if (path.endsWith('/canvas/objects')) {
    return {'objects': <Object>[], 'has_more': false, 'latest_seq': 0};
  }
  return <Object>[];
}

class _Session {
  _Session(this.db, this.writes) {
    fixture = CanvasPaneFixture();
    container = fixture.container(
      extraOverrides: [
        databaseProvider.overrideWith((ref) async => db),
        mockApiOverride((request) async {
          if (request.method != 'GET') writes.add(request);
          return jsonResponse(_get(request.url.path));
        }),
      ],
    );
  }

  final SlimmDatabase db;
  final List<http.Request> writes;
  late final CanvasPaneFixture fixture;
  late final ProviderContainer container;

  Future<CanvasEngine> open(String channelId) async {
    container.listen(canvasEngineProvider(channelId), (_, _) {});
    final engine = container.read(canvasEngineProvider(channelId).notifier);
    engine.document.setViewport(_viewport);
    await _settle();
    return engine;
  }

  Future<void> close() async {
    container.dispose();
    await fixture.events.close();
    await _settle();
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

Camera _zoomedCamera() =>
    Camera(x: 1500, y: 1100, zoom: boardFitZoom(canvasBoard, _viewport) * 3);

void _arrange(CanvasEngine engine) {
  engine.tileOverrides.applyServer(
    'screen:a',
    rect: const Rect.fromLTWH(100, 100, 360, 203),
    locked: false,
    sentToBack: false,
  );
  engine.viewMode.showPersonal();
  engine.document.setCamera(_zoomedCamera());
  engine.tileOverrides.setRect('screen:a', _place);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SlimmDatabase db;
  late List<http.Request> writes;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    writes = [];
  });
  tearDown(() => db.close());

  test(
    'the layout is back after closing the canvas and opening it again',
    () async {
      final first = _Session(db, writes);
      final engine = await first.open('c1');
      _arrange(engine);
      final camera = engine.document.camera;
      await first.close();

      final second = _Session(db, writes);
      addTearDown(second.close);
      final reopened = await second.open('c1');

      expect(reopened.viewMode.personal, isTrue);
      expect(reopened.document.camera, camera);
      expect(reopened.tileOverrides.stateFor('screen:a').rect, _place);
    },
  );

  test('the layout survives an app restart', () async {
    final dir = await Directory.systemTemp.createTemp('slimm-personal-layout');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/slimm.sqlite');
    final before = SlimmDatabase(NativeDatabase(file));
    final first = _Session(before, writes);
    final engine = await first.open('c1');
    _arrange(engine);
    final camera = engine.document.camera;
    await first.close();
    await before.close();

    final after = SlimmDatabase(NativeDatabase(file));
    addTearDown(after.close);
    final second = _Session(after, writes);
    addTearDown(second.close);
    final reopened = await second.open('c1');

    expect(reopened.document.camera, camera);
    expect(reopened.tileOverrides.stateFor('screen:a').rect, _place);
  });

  test(
    'a layout left in the shared view reopens shared and keeps the rest',
    () async {
      final first = _Session(db, writes);
      final engine = await first.open('c1');
      _arrange(engine);
      engine.viewMode.showShared();
      await first.close();

      final second = _Session(db, writes);
      addTearDown(second.close);
      final reopened = await second.open('c1');

      expect(reopened.viewMode.personal, isFalse);
      reopened.viewMode.showPersonal();
      expect(reopened.tileOverrides.stateFor('screen:a').rect, _place);
    },
  );

  test('another channel keeps its own layout', () async {
    final first = _Session(db, writes);
    final engine = await first.open('c1');
    _arrange(engine);
    await first.close();

    final second = _Session(db, writes);
    addTearDown(second.close);
    final other = await second.open('c2');

    expect(other.viewMode.personal, isFalse);
    expect(other.viewMode.hasLayout, isFalse);
    expect(other.tileOverrides.personalPlaces, isEmpty);
  });

  test('reset forgets the layout for good', () async {
    final first = _Session(db, writes);
    final engine = await first.open('c1');
    _arrange(engine);
    await _settle();
    engine.viewMode.reset();
    await first.close();

    expect(await CanvasLayoutStore(db).load('c1'), isNull);
    final second = _Session(db, writes);
    addTearDown(second.close);
    final reopened = await second.open('c1');
    expect(reopened.viewMode.personal, isFalse);
    expect(reopened.viewMode.hasLayout, isFalse);
  });

  test(
    'following someone shows the shared view and keeps the layout',
    () async {
      final session = _Session(db, writes);
      addTearDown(session.close);
      final engine = await session.open('c1');
      _arrange(engine);
      final camera = engine.document.camera;

      engine.viewRelay.follow('them');

      expect(engine.viewMode.personal, isFalse);
      engine.viewRelay.stopFollowing();
      engine.viewMode.showPersonal();
      expect(engine.document.camera, camera);
      expect(engine.tileOverrides.stateFor('screen:a').rect, _place);
    },
  );

  test('being summoned shows the shared view and keeps the layout', () async {
    final session = _Session(db, writes);
    addTearDown(session.close);
    final engine = await session.open('c1');
    _arrange(engine);

    engine.viewRelay.applyRemote(
      'them',
      const Rect.fromLTWH(500, 400, 800, 450),
      summon: true,
    );

    expect(engine.viewMode.personal, isFalse);
    expect(engine.viewMode.hasLayout, isTrue);
    engine.viewMode.showPersonal();
    expect(engine.tileOverrides.stateFor('screen:a').rect, _place);
  });

  test(
    'a stored place and camera outside the board come back inside it',
    () async {
      final stored = CanvasPersonalLayout(
        personal: true,
        camera: Camera(
          x: 9e6,
          y: -9e6,
          zoom: boardFitZoom(canvasBoard, _viewport),
        ),
        places: {
          'screen:a': const Rect.fromLTWH(9e6, 9e6, 360, 203),
          'camera:ghost': const Rect.fromLTWH(10, 10, 100, 100),
        },
      );
      await CanvasLayoutStore(db).save('c1', stored.encode(), now: 1);

      final session = _Session(db, writes);
      addTearDown(session.close);
      final engine = await session.open('c1');

      final rect = engine.tileOverrides.stateFor('screen:a').rect!;
      expect(canvasBoard.contains(rect.topLeft), isTrue);
      expect(rect.right, lessThanOrEqualTo(canvasBoard.right));
      expect(rect.bottom, lessThanOrEqualTo(canvasBoard.bottom));
      final view = engine.document.worldView;
      expect(view.left, greaterThanOrEqualTo(canvasBoard.left - 1e-6));
      expect(view.right, lessThanOrEqualTo(canvasBoard.right + 1e-6));
      expect(engine.tileOverrides.stateFor('camera:other').rect, isNull);
    },
  );

  test('opening a canvas does not rewrite the layout it restored', () async {
    const stored = CanvasPersonalLayout(
      personal: true,
      camera: Camera(x: 1500, y: 1100, zoom: 0.5),
      places: {'screen:a': _place},
    );
    await CanvasLayoutStore(db).save('c1', stored.encode(), now: 1);

    final session = _Session(db, writes);
    addTearDown(session.close);
    await session.open('c1');
    await Future<void>.delayed(personalLayoutSaveDelay * 3);

    final rows = await db.select(db.canvasPersonalLayouts).get();
    expect(rows.single.updatedAt, 1, reason: 'restoring is not an edit');
  });

  test('a fitted personal camera is saved as fitted, not as a zoom', () async {
    final session = _Session(db, writes);
    addTearDown(session.close);
    final engine = await session.open('c1');
    engine.viewMode.showPersonal();
    engine.tileOverrides.setRect('screen:a', _place);
    await Future<void>.delayed(personalLayoutSaveDelay * 3);

    final saved = CanvasPersonalLayout.decode(
      (await CanvasLayoutStore(db).load('c1'))!,
    )!;
    expect(saved.camera, isNull);
    expect(saved.places, {'screen:a': _place});
  });

  test('an unreadable stored layout opens the shared view', () async {
    await CanvasLayoutStore(db).save('c1', '{not json', now: 1);

    final session = _Session(db, writes);
    addTearDown(session.close);
    final engine = await session.open('c1');

    expect(engine.viewMode.personal, isFalse);
  });

  test('nothing about the layout is ever sent to the server', () async {
    final first = _Session(db, writes);
    final engine = await first.open('c1');
    writes.clear();
    _arrange(engine);
    engine.viewMode.showShared();
    engine.viewMode.showPersonal();
    engine.viewMode.reset();
    await first.close();

    final second = _Session(db, writes);
    addTearDown(second.close);
    await second.open('c1');

    expect(writes, isEmpty);
  });

  test('a pan is written once it settles, not on every frame', () async {
    final session = _Session(db, writes);
    addTearDown(session.close);
    final engine = await session.open('c1');
    engine.viewMode.showPersonal();
    engine.document.setCamera(_zoomedCamera());

    expect(await CanvasLayoutStore(db).load('c1'), isNull);
    await Future<void>.delayed(personalLayoutSaveDelay * 2);

    expect(await CanvasLayoutStore(db).load('c1'), isNotNull);
  });

  test(
    'edits made while the saved layout loads are merged and written',
    () async {
      const stored = CanvasPersonalLayout(
        personal: true,
        places: {'screen:b': Rect.fromLTWH(10, 10, 100, 60)},
      );
      await CanvasLayoutStore(db).save('c1', stored.encode(), now: 1);
      final document = CanvasDocument()
        ..setBoard(canvasBoard)
        ..setViewport(_viewport);
      final tiles = CanvasPresenceTileOverrides()..board = canvasBoard;
      final mode = CanvasViewMode(document: document, tiles: tiles);
      final opened = Completer<CanvasLayoutStore?>();
      final keeper = CanvasPersonalLayoutKeeper(
        channelId: 'c1',
        mode: mode,
        store: opened.future,
        saveDelay: const Duration(milliseconds: 10),
      );
      addTearDown(() {
        keeper.dispose();
        mode.dispose();
        tiles.dispose();
        document.dispose();
      });

      final restoring = keeper.restore();
      mode.showPersonal();
      tiles.setRect('screen:a', _place);
      opened.complete(CanvasLayoutStore(db));
      await restoring;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final saved = CanvasPersonalLayout.decode(
        (await CanvasLayoutStore(db).load('c1'))!,
      )!;
      expect(saved.places.keys, containsAll(['screen:a', 'screen:b']));
      expect(saved.places['screen:a'], _place);
    },
  );
}
