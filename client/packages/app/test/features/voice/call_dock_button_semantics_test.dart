// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call dock button says its name once: the tooltip that names it, with or
/// without a shortcut after the name, is not announced on top of the label.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/semantics_audit.dart';

Future<SemanticsNode> _node(WidgetTester tester, CallDockButton button) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(body: Center(child: button)),
    ),
  );
  return tester.getSemantics(find.bySemanticsLabel(RegExp('^Mute')).first);
}

void main() {
  testWidgets('a tooltip that is the whole name is said once', (tester) async {
    final handle = tester.ensureSemantics();
    final node = await _node(
      tester,
      CallDockButton(
        icon: AppIcons.mic,
        tooltip: 'Mute',
        active: false,
        onPressed: () {},
      ),
    );
    expect(doubledName(node.label, node.tooltip), isNull);
    handle.dispose();
  });

  testWidgets('a tooltip adding a shortcut to the name is said once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final node = await _node(
      tester,
      CallDockButton(
        icon: AppIcons.mic,
        tooltip: 'Mute (Ctrl+Shift+M)',
        semanticLabel: 'Mute',
        active: false,
        onPressed: () {},
      ),
    );
    expect(doubledName(node.label, node.tooltip), isNull);
    handle.dispose();
  });

  testWidgets('the shortcut a tooltip adds is kept as the hint', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final node = await _node(
      tester,
      CallDockButton(
        icon: AppIcons.mic,
        tooltip: 'Mute (Ctrl+Shift+M)',
        semanticLabel: 'Mute',
        active: false,
        onPressed: () {},
      ),
    );
    expect(node.label, 'Mute');
    expect(node.hint, '(Ctrl+Shift+M)');
    handle.dispose();
  });

  testWidgets('an empty label falls back to the tooltip as the name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final node = await _node(
      tester,
      CallDockButton(
        icon: AppIcons.mic,
        tooltip: 'Mute',
        semanticLabel: '',
        active: false,
        onPressed: () {},
      ),
    );
    expect(node.label, 'Mute');
    expect(doubledName(node.label, node.tooltip), isNull);
    handle.dispose();
  });
}
