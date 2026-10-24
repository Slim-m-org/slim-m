// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slot renderer draws every node type without overflow at a pane width
/// and a desktop width, and says progress in text and to a screen reader.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_slot_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _long =
    'A very long line of module text that cannot possibly fit in a narrow '
    'member card and so has to end in an ellipsis instead of overflowing';

Future<void> _pump(
  WidgetTester tester,
  api.ModuleSlotItem item, {
  double width = 240,
  bool inline = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: ModuleSlotView(item, source: 'xp', inline: inline),
        ),
      ),
    ),
  ),
);

api.ModuleSlotItem _everything() => const api.ModuleSlotItem(
  nodes: [
    api.ModuleSlotText(_long, tone: api.ModuleSlotTone.accent),
    api.ModuleSlotProgress(value: 7, max: 10, label: 'Level 3'),
    api.ModuleSlotRow([
      api.ModuleSlotIcon('play'),
      api.ModuleSlotBadge(_long, icon: 'list'),
      api.ModuleSlotText(_long, tone: api.ModuleSlotTone.muted),
    ]),
    api.ModuleSlotStack([
      api.ModuleSlotText('nested'),
      api.ModuleSlotProgress(value: 1.5, max: 3),
    ]),
  ],
);

void main() {
  for (final width in const [240.0, 900.0]) {
    testWidgets('every node type fits at ${width.round()}dp', (tester) async {
      await _pump(tester, _everything(), width: width);

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ModuleSlotView)).width,
        lessThanOrEqualTo(width),
      );
      expect(find.text('nested'), findsOneWidget);
      expect(find.byIcon(AppIcons.play), findsOneWidget);
    });
  }

  testWidgets('long text ends in an ellipsis at a narrow width', (
    tester,
  ) async {
    await _pump(tester, _everything());

    final texts = tester.widgetList<Text>(find.text(_long));
    expect(texts, isNotEmpty);
    for (final text in texts) {
      expect(text.overflow, TextOverflow.ellipsis);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress is text and announces value of max', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [api.ModuleSlotProgress(value: 7, max: 10, label: 'Level 3')],
      ),
    );

    expect(find.text('Level 3'), findsOneWidget);
    expect(find.text('7 / 10'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Level 3')).value,
      '7 of 10',
    );
    handle.dispose();
  });

  testWidgets('a fractional progress value keeps one decimal', (tester) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [api.ModuleSlotProgress(value: 1.5, max: 3)],
      ),
    );

    expect(find.text('1.5 / 3'), findsOneWidget);
  });

  testWidgets('the bar fills in proportion to the value', (tester) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [api.ModuleSlotProgress(value: 5, max: 10)],
      ),
    );

    final fill = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(fill.widthFactor, 0.5);
  });

  testWidgets('with no nodes the fallback shows as muted text', (tester) async {
    await _pump(tester, const api.ModuleSlotItem(fallback: 'Level 12'));

    final text = tester.widget<Text>(find.text('Level 12'));
    final tokens = Theme.of(
      tester.element(find.text('Level 12')),
    ).extension<AppTokens>()!;
    expect(text.style!.color, tokens.textSecondary);
  });

  testWidgets('nodes win over the fallback', (tester) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [api.ModuleSlotText('drawn')],
        fallback: 'fallback',
      ),
    );

    expect(find.text('drawn'), findsOneWidget);
    expect(find.text('fallback'), findsNothing);
  });

  testWidgets('nothing at all draws nothing', (tester) async {
    await _pump(tester, api.ModuleSlotItem.empty);

    expect(tester.getSize(find.byType(ModuleSlotView)).height, 0);
  });

  testWidgets('an unknown icon draws no glyph', (tester) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [
          api.ModuleSlotRow([
            api.ModuleSlotIcon(null),
            api.ModuleSlotText('x'),
          ]),
        ],
      ),
    );

    expect(find.byType(Icon), findsNothing);
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('accent tone uses the accent token and normal does not', (
    tester,
  ) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(
        nodes: [
          api.ModuleSlotText('loud', tone: api.ModuleSlotTone.accent),
          api.ModuleSlotText('plain'),
        ],
      ),
    );

    final tokens = Theme.of(
      tester.element(find.text('loud')),
    ).extension<AppTokens>()!;
    expect(tester.widget<Text>(find.text('loud')).style!.color, tokens.accent);
    expect(
      tester.widget<Text>(find.text('plain')).style!.color,
      tokens.textPrimary,
    );
  });

  testWidgets('a badge is capped to its parent and keeps its text', (
    tester,
  ) async {
    await _pump(
      tester,
      const api.ModuleSlotItem(nodes: [api.ModuleSlotBadge(_long)]),
      width: 120,
      inline: true,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(AppBadge), findsOneWidget);
    expect(tester.getSize(find.byType(AppBadge)).width, lessThanOrEqualTo(120));
  });
}
