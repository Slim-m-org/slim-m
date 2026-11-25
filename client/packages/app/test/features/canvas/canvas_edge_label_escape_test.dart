// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Escape in a connection's label input closes only that input; it does not put the armed tool down.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_text_focus.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Map<String, dynamic> _note(String id, double x, int seq) => {
  ...canvasNoteJson(id, x: x, seq: seq),
  'y': 100.0,
  'w': 120.0,
  'h': 60.0,
};

bool _active(WidgetTester tester, String label) =>
    tester
        .widget<AppIconButton>(
          find
              .ancestor(
                of: find.bySemanticsLabel(label),
                matching: find.byWidgetPredicate((w) => w is AppIconButton),
              )
              .first,
        )
        .active ==
    true;

void main() {
  testWidgets('Escape in the label input keeps the Connect tool armed', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    fixture.routes = (request) async => request.url.path == '/version'
        ? jsonResponse({
            'name': 'slim-m',
            'version': '0.118.0',
            'protocol': 1,
            'push_enabled': false,
            'invite_required': false,
            'claimed': true,
            'canvas_edges': true,
          })
        : null;
    fixture.objects = [
      _note('a', 100, 1),
      _note('b', 400, 2),
      {
        'id': 'e',
        'kind': 'edge',
        'z_index': 3,
        'x': 100.0,
        'y': 100.0,
        'w': 420.0,
        'h': 60.0,
        'props': {
          'from': {'object_id': 'a'},
          'to': {'object_id': 'b'},
          'arrow': 'end',
        },
        'author_id': 'me',
        'created_at': 0,
        'seq': 3,
      },
    ];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, tool: 'Pan');
    final document = surfaceDocument(tester);
    await waitUntil(tester, () => document.edges.isAlive('e'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();

    document.selectedObjectId.value = 'e';
    document.edges.labelEdit.value = 'e';
    await tester.pump(const Duration(milliseconds: 300));
    expect(textInputHasFocus(), isTrue, reason: 'baseline: the input is open');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));

    expect(textInputHasFocus(), isFalse);
    expect(_active(tester, 'Connect'), isTrue);
  });
}
