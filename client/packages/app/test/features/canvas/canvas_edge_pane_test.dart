// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connections through the whole pane (decision 0137): the Connect tool, the side dots, re-attaching an end, the label and Delete, with the geometry of every press asserted.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_edge_style.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_edge_layer.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Map<String, dynamic> _note(String id, double x, double y, int seq) => {
  ...canvasNoteJson(id, x: x, seq: seq),
  'y': y,
  'w': 120.0,
  'h': 60.0,
};

Map<String, dynamic> _edge(String id, String from, String to, int seq) => {
  'id': id,
  'kind': 'edge',
  'z_index': seq,
  'x': 100.0,
  'y': 100.0,
  'w': 420.0,
  'h': 60.0,
  'props': {
    'from': {'object_id': from},
    'to': {'object_id': to},
    'arrow': 'end',
  },
  'author_id': 'me',
  'seq': seq,
  'created_at': 0,
};

Future<CanvasPaneFixture> _open(
  WidgetTester tester, {
  bool edges = true,
  List<Map<String, dynamic>> extra = const [],
}) async {
  final fixture = CanvasPaneFixture();
  fixture.routes = (request) async => request.url.path == '/version'
      ? jsonResponse({
          'name': 'slim-m',
          'version': '0.118.0',
          'protocol': 1,
          'push_enabled': false,
          'invite_required': false,
          'claimed': true,
          'canvas_edges': edges,
        })
      : null;
  fixture
    ..objects = [
      _note('a', 100, 100, 1),
      _note('b', 400, 100, 2),
      _note('c', 400, 300, 3),
      _edge('e', 'a', 'b', 4),
      ...extra,
    ];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: 'Pan');
  final document = surfaceDocument(tester);
  await waitUntil(
    tester,
    () => document.edges.isAlive('e') && document.isAlive('c'),
  );
  await waitUntil(
    tester,
    () => container.read(canvasEdgesSupportedProvider) == edges,
  );
  return fixture;
}

Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) async {
  final gesture = await tester.startGesture(from, kind: kind);
  const steps = 8;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

Offset _at(WidgetTester tester, Offset world) => screenFor(tester, world);

void main() {
  testWidgets(
    'a press on the line selects the connection and Delete erases it',
    (tester) async {
      final fixture = await _open(tester);
      final document = surfaceDocument(tester);
      final route = document.edges.routeOf(document.edges.liveEdge('e')!)!;
      expect(route.start, const Offset(220, 130));
      expect(route.end, const Offset(400, 130));

      final gesture = await tester.startGesture(
        _at(tester, route.midpoint),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();

      expect(document.selectedObjectId.value, 'e');
      expect(find.bySemanticsLabel('Delete connection'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await waitUntil(tester, () => fixture.postedOps.isNotEmpty);
      expect(fixture.postedOps.single['kind'], 'remove');
      expect(fixture.postedOps.single['object_ids'], ['e']);
      expect(document.edges.isAlive('e'), isFalse);
    },
  );

  testWidgets('a press beside the line selects nothing', (tester) async {
    await _open(tester);
    final document = surfaceDocument(tester);
    final route = document.edges.routeOf(document.edges.liveEdge('e')!)!;
    final gesture = await tester.startGesture(
      _at(tester, route.midpoint + const Offset(0, 40)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pump();
    expect(document.selectedObjectId.value, isNull);
  });

  testWidgets('the Connect tool draws a connection from one note to another', (
    tester,
  ) async {
    final fixture = await _open(tester);
    await tester.tap(find.bySemanticsLabel('Connect'));
    await tester.pump();

    // From the middle of the note to the middle of the one below it.
    await _drag(
      tester,
      _at(tester, const Offset(460, 130)),
      _at(tester, const Offset(460, 330)),
    );
    await waitUntil(
      tester,
      () => fixture.posted.any((p) => p['kind'] == 'edge'),
    );

    final placed = fixture.posted.singleWhere((p) => p['kind'] == 'edge');
    final props = placed['props'] as Map<String, dynamic>;
    expect(props['from'], {'object_id': 'b'});
    expect(props['to'], {'object_id': 'c'});
    expect(props['arrow'], 'end');
    final document = surfaceDocument(tester);
    expect(document.edges.attachedTo('c').length, 1);
    expect(document.selectedObjectId.value, placed['id']);
  });

  testWidgets(
    'a connection dropped on empty board keeps a free end where it was let go',
    (tester) async {
      final fixture = await _open(tester);
      await tester.tap(find.bySemanticsLabel('Connect'));
      await tester.pump();
      await _drag(
        tester,
        _at(tester, const Offset(160, 130)),
        _at(tester, const Offset(300, 450)),
      );
      await waitUntil(
        tester,
        () => fixture.posted.any((p) => p['kind'] == 'edge'),
      );
      final props = fixture.posted.single['props'] as Map<String, dynamic>;
      expect(props['from'], {'object_id': 'a'});
      expect(props['to'], {'x': 300.0, 'y': 450.0});
    },
  );

  testWidgets('a click that goes nowhere draws nothing', (tester) async {
    final fixture = await _open(tester);
    await tester.tap(find.bySemanticsLabel('Connect'));
    await tester.pump();
    final gesture = await tester.startGesture(
      _at(tester, const Offset(160, 130)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pump();
    expect(fixture.posted.where((p) => p['kind'] == 'edge'), isEmpty);
  });

  testWidgets(
    'a selected note shows four dots and a drag from one starts at that side',
    (tester) async {
      final fixture = await _open(tester);
      final document = surfaceDocument(tester);
      await tester.tapAt(_at(tester, const Offset(160, 130)));
      await tester.pump();
      expect(document.edges.dotsOn.value, 'a');

      // The bottom dot of note a, to the middle of note c.
      await _drag(
        tester,
        _at(tester, const Offset(160, 160)),
        _at(tester, const Offset(460, 330)),
        kind: PointerDeviceKind.touch,
      );
      await waitUntil(
        tester,
        () => fixture.posted.any((p) => p['kind'] == 'edge'),
      );
      final props = fixture.posted.single['props'] as Map<String, dynamic>;
      expect(props['from'], {'object_id': 'a', 'side': 'bottom'});
      expect(props['to'], {'object_id': 'c'});
    },
  );

  testWidgets(
    'dragging an end handle onto another note re-attaches it with one edit',
    (tester) async {
      final fixture = await _open(tester);
      final document = surfaceDocument(tester);
      final route = document.edges.routeOf(document.edges.liveEdge('e')!)!;
      await tester.tapAt(_at(tester, route.midpoint));
      await tester.pump();
      expect(document.selectedObjectId.value, 'e');

      await _drag(
        tester,
        _at(tester, route.end),
        _at(tester, const Offset(460, 330)),
      );
      await waitUntil(
        tester,
        () => fixture.postedOps.any((o) => o['kind'] == 'edit'),
      );

      final edit = fixture.postedOps.singleWhere((o) => o['kind'] == 'edit');
      expect(edit['object_id'], 'e');
      expect(edit['props'], {
        'to': {'object_id': 'c'},
      });
      expect(
        (document.edges.liveEdge('e')!.spec.to as AttachedEnd).objectId,
        'c',
      );
    },
  );

  testWidgets('a drag that would free both ends snaps back and sends nothing', (
    tester,
  ) async {
    final fixture = await _open(
      tester,
      extra: [
        {
          ..._edge('f', 'a', 'b', 5),
          'props': {
            'from': {'object_id': 'a'},
            'to': {'x': 700.0, 'y': 500.0},
          },
        },
      ],
    );
    final document = surfaceDocument(tester);
    final edge = document.edges.liveEdge('f')!;
    await waitUntil(tester, () => document.edges.routeOf(edge) != null);
    final route = document.edges.routeOf(edge)!;
    await tester.tapAt(_at(tester, route.pointAt(0.5)));
    await tester.pump();
    expect(document.selectedObjectId.value, 'f');

    await _drag(
      tester,
      _at(tester, route.start),
      _at(tester, const Offset(650, 560)),
    );
    expect(fixture.postedOps.where((o) => o['kind'] == 'edit'), isEmpty);
    expect(document.edges.liveEdge('f')!.spec.from, const AttachedEnd('a'));
  });

  testWidgets(
    'Enter on a selected connection opens its label and saving sends one edit',
    (tester) async {
      final fixture = await _open(tester);
      final document = surfaceDocument(tester);
      final route = document.edges.routeOf(document.edges.liveEdge('e')!)!;
      await tester.tapAt(_at(tester, route.midpoint));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(document.edges.labelEdit.value, 'e');
      expect(find.byKey(canvasEdgeLabelFieldKey), findsOneWidget);

      await tester.enterText(find.byKey(canvasEdgeLabelFieldKey), ' needs ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await waitUntil(
        tester,
        () => fixture.postedOps.any((o) => o['kind'] == 'edit'),
      );
      expect(fixture.postedOps.single['props'], {'label': 'needs'});
      expect(document.edges.liveEdge('e')!.spec.label, 'needs');
    },
  );

  testWidgets(
    'a server that predates connections shows no Connect tool and ignores C',
    (tester) async {
      await _open(tester, edges: false);
      expect(find.bySemanticsLabel('Connect'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      final document = surfaceDocument(tester);
      final press = await tester.startGesture(
        _at(tester, const Offset(160, 130)),
        kind: PointerDeviceKind.mouse,
      );
      await press.up();
      await tester.pump();
      expect(document.edges.dotsOn.value, isNull);
    },
  );

  testWidgets(
    'a remote move of an end re-routes the connection on the next frame',
    (tester) async {
      await _open(tester);
      final document = surfaceDocument(tester);
      final edge = document.edges.liveEdge('e')!;
      final before = document.edges.routeOf(edge)!.end;
      document
        ..moveObject('b', 400, 300, 120, 60)
        ..refresh();
      await tester.pump();
      final after = document.edges.routeOf(edge)!.end;
      expect(before, const Offset(400, 130));
      expect(after.dy, isNot(before.dy));
    },
  );
}
