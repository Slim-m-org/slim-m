// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-198: on a wide window a screen reader reads the toolbar, the board, then the side panes.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_data/data.dart';

import 'features/settings/home_shell_harness.dart';

void _walk(SemanticsNode node, List<String> out) {
  if (node.label.isNotEmpty) out.add(node.label);
  for (final child in node.debugListChildrenInOrder(
    DebugSemanticsDumpOrder.traversalOrder,
  )) {
    _walk(child, out);
  }
}

void main() {
  testWidgets('wide window: toolbar, board, then side panes', (tester) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    s.container.read(canvasOpenProvider.notifier).state = 'c1';
    final handle = tester.ensureSemantics();
    await pumpAtWidth(tester, s.container, 1600, location: '/channels/c1');
    final order = <String>[];
    _walk(
      tester
          .getSemantics(find.bySemanticsLabel('Close canvas'))
          .owner!
          .rootSemanticsNode!,
      order,
    );
    int at(String label) => order.indexWhere((l) => l.startsWith(label));
    final steps = [
      'Space menu',
      'Toggle member list',
      'Canvas board',
      'Close canvas',
      'MEMBERS',
    ];
    for (final step in steps) {
      expect(at(step), isNonNegative, reason: '$step is read: $order');
    }
    expect(
      steps.map(at).toList(),
      orderedEquals(steps.map(at).toList()..sort()),
    );
    handle.dispose();
    await teardown(tester, s.container, s.db);
  });
}
