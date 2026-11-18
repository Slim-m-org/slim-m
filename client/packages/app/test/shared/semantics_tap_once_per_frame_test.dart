// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:ui' show SemanticsActionEvent;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/semantics_tap_once_per_frame.dart';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialog) => AlertDialog(
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialog).pop(),
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
            child: const Text('home'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('home'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void _tapTwiceInOneTick(WidgetTester tester, String label) {
  final node = tester.semantics.find(find.bySemanticsLabel(label));
  final event = SemanticsActionEvent(
    type: SemanticsAction.tap,
    viewId: tester.view.viewId,
    nodeId: node.id,
  );
  final dispatch = tester.binding.platformDispatcher.onSemanticsActionEvent!;
  dispatch(event);
  dispatch(event);
}

void main() {
  testWidgets('a doubled tap on a sheet button pops only the sheet', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final dispatcher = tester.binding.platformDispatcher;
    final original = dispatcher.onSemanticsActionEvent;
    addTearDown(() => dispatcher.onSemanticsActionEvent = original);
    SemanticsTapOncePerFrame.install(dispatcher, tester.binding);
    await _openSheet(tester);

    _tapTwiceInOneTick(tester, 'Send');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Send'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('taps in separate frames each go through', (tester) async {
    final semantics = tester.ensureSemantics();
    final dispatcher = tester.binding.platformDispatcher;
    final original = dispatcher.onSemanticsActionEvent;
    addTearDown(() => dispatcher.onSemanticsActionEvent = original);
    var taps = 0;
    SemanticsTapOncePerFrame.install(dispatcher, tester.binding);
    await tester.pumpWidget(
      MaterialApp(
        home: TextButton(onPressed: () => taps++, child: const Text('count')),
      ),
    );

    final dispatch = dispatcher.onSemanticsActionEvent!;
    final event = SemanticsActionEvent(
      type: SemanticsAction.tap,
      viewId: tester.view.viewId,
      nodeId: tester.semantics.find(find.bySemanticsLabel('count')).id,
    );
    dispatch(event);
    await tester.pump();
    dispatch(event);
    await tester.pump();

    expect(taps, 2);
    semantics.dispose();
  });
}
