// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Widget tests for the form controls in `components/forms`.
///
/// The slider's "tall, muted, metered with ticks" case exists because the custom
/// track and thumb paint code is the newest, highest-risk part of that widget.
/// It exercises every optional feature at once so a bad rect (for example a
/// meter fraction that clips negative) surfaces here rather than the first time
/// a caller combines them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('AppInput', () {
    testWidgets('shows its placeholder', (tester) async {
      await tester
          .pumpWidget(_wrap(const AppInput(placeholder: 'Search messages')));

      expect(find.text('Search messages'), findsOneWidget);
    });

    testWidgets('surfaces an error state as visible text', (tester) async {
      await tester.pumpWidget(
          _wrap(const AppInput(errorText: 'This field is required')));

      expect(find.text('This field is required'), findsOneWidget);
    });

    testWidgets('reports focus when the field is tapped', (tester) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
          _wrap(AppInput(focusNode: focusNode, placeholder: 'Name')));
      expect(focusNode.hasFocus, isFalse);

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
    });
  });

  group('AppChip', () {
    testWidgets('reaction variant shows its count and reflects active',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppChip.reaction(
                  emoji: '\u{1F44D}', count: 3, active: true, onTap: () {}),
              AppChip.reaction(
                  emoji: '\u{1F44D}', count: 5, active: false, onTap: () {}),
            ],
          ),
        ),
      );

      expect(find.text('3'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);

      // Active state is not colour alone: it also carries a heavier weight on the count.
      final activeCount = tester.widget<Text>(find.text('3'));
      final inactiveCount = tester.widget<Text>(find.text('5'));
      expect(activeCount.style?.fontWeight, AppWeights.semi);
      expect(inactiveCount.style?.fontWeight, AppWeights.regular);
    });

    testWidgets(
        'a reacted chip draws no separate marker widget: only its fill and '
        'weight differ from an unreacted one', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppChip.reaction(
                  emoji: '\u{1F44D}', count: 3, active: true, onTap: () {}),
              AppChip.reaction(
                  emoji: '\u{1F44D}', count: 5, active: false, onTap: () {}),
            ],
          ),
        ),
      );

      // Same child count on both: nothing (a dot, an icon) is inserted ahead of the emoji for the active one.
      final rows =
          tester.widgetList<Row>(find.byType(Row)).toList(growable: false);
      expect(rows, hasLength(2));
      expect(rows[0].children.length, rows[1].children.length);
    });

    testWidgets('reaction glyph resolves a colour emoji fallback',
        (tester) async {
      await tester.pumpWidget(
        _wrap(AppChip.reaction(
            emoji: '\u{1F44D}', count: 1, active: false, onTap: () {})),
      );

      // Unnamed, fontconfig hands back monochrome Noto Emoji on Fedora.
      final resolved = tester
          .renderObject<RenderParagraph>(find.text('\u{1F44D}'))
          .text
          .style;
      expect(resolved?.fontFamilyFallback, contains('Noto Color Emoji'));
    });

    testWidgets(
        'reaction chip padding and internal gap sit at the tightest '
        'spacing token, s4 rather than s8', (tester) async {
      await tester.pumpWidget(
        _wrap(AppChip.reaction(
            emoji: '\u{1F44D}', count: 1, active: false, onTap: () {})),
      );

      // The decorated chip is the only Container with a fill colour.
      final visual = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color != null);
      expect(visual.padding,
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4));

      final gap = tester.widget<SizedBox>(find.byType(SizedBox));
      expect(gap.width, AppSpacing.s4);
    });

    testWidgets(
        'a reacted chip draws exactly one accent ring, even once it also '
        'gains real keyboard focus', (tester) async {
      // The highlight only paints for traditional (keyboard) focus; core_test.dart's AppListRow test forces it the same way.
      final previousStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
          () => FocusManager.instance.highlightStrategy = previousStrategy);

      await tester.pumpWidget(
        _wrap(AppChip.reaction(
            emoji: '\u{1F44D}', count: 2, active: true, onTap: () {})),
      );

      // Container only, since Container.build() wraps its own decoration in a DecoratedBox and would double-count.
      Iterable<Color?> ringColors() => tester
          .widgetList<Container>(find.descendant(
              of: find.byType(AppChip), matching: find.byType(Container)))
          .map((c) => (c.decoration as BoxDecoration?)?.border?.top.color);

      // Not focused yet: reacted alone draws no accent-coloured ring at all.
      expect(
        ringColors().where((c) => c == AppTokens.light.accentFill),
        isEmpty,
      );

      final focusNode = tester
          .widget<Focus>(find.descendant(
              of: find.byType(AppChip), matching: find.byType(Focus)))
          .focusNode!;
      focusNode.requestFocus();
      // Two frames: FocusManager applies a request on the frame after the one it arrived on.
      await tester.pump();
      await tester.pump();

      // Focused and reacted at once: exactly one ring, since focusRing and accentFill are equal.
      expect(
        ringColors().where((c) => c == AppTokens.light.accentFill).length,
        1,
      );
    });

    testWidgets('a reacted chip draws no ring at all from an ordinary tap',
        (tester) async {
      await tester.pumpWidget(
        _wrap(AppChip.reaction(
            emoji: '\u{1F44D}', count: 2, active: true, onTap: () {})),
      );

      // The default test strategy is automatic, and a tap is touch input, so this must stay ring-free.
      await tester.tap(find.byType(AppChip));
      await tester.pump();

      final ringColors = tester
          .widgetList<Container>(find.descendant(
              of: find.byType(AppChip), matching: find.byType(Container)))
          .map((c) => (c.decoration as BoxDecoration?)?.border?.top.color);
      expect(ringColors.where((c) => c == AppTokens.light.accentFill), isEmpty);
    });
  });

  group('AppToggle', () {
    testWidgets('flips and reports its value through onChanged',
        (tester) async {
      bool? reported;
      await tester.pumpWidget(
          _wrap(AppToggle(value: false, onChanged: (v) => reported = v)));

      await tester.tap(find.byType(AppToggle));
      await tester.pump();

      expect(reported, isTrue);
    });

    testWidgets('wires no tap handler when disabled', (tester) async {
      await tester
          .pumpWidget(_wrap(const AppToggle(value: false, onChanged: null)));

      // A disabled toggle must not merely ignore the callback: the tap handler
      // is absent, so assistive tech reports it non-interactive, not a button.
      final gestureDetector =
          tester.widget<GestureDetector>(find.byType(GestureDetector));
      expect(gestureDetector.onTap, isNull);

      await tester.tap(find.byType(AppToggle));
      await tester.pump();
    });

    testWidgets('a locked toggle reports on but wires no tap handler',
        (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(AppToggle(
            value: true, locked: true, onChanged: (v) => called = true)),
      );

      final gestureDetector =
          tester.widget<GestureDetector>(find.byType(GestureDetector));
      expect(gestureDetector.onTap, isNull);

      await tester.tap(find.byType(AppToggle));
      await tester.pump();

      expect(called, isFalse);
    });
  });

  group('AppSegmentedControl', () {
    testWidgets(
        'inline variant reports the selected index and signals it beyond colour',
        (tester) async {
      var selectedIndex = 0;
      int? reported;

      await tester.pumpWidget(
        _wrap(
          StatefulBuilder(
            builder: (context, setState) => AppSegmentedControl.inline(
              options: const [
                AppSegmentedOption(label: 'Day'),
                AppSegmentedOption(label: 'Week')
              ],
              selectedIndex: selectedIndex,
              onSegmentSelected: (i) {
                reported = i;
                setState(() => selectedIndex = i);
              },
            ),
          ),
        ),
      );

      var dayText = tester.widget<Text>(find.text('Day'));
      var weekText = tester.widget<Text>(find.text('Week'));
      // Inline selection is never accent-coloured: a raised surface plus a
      // border plus weight carries it instead.
      expect(dayText.style?.fontWeight, AppWeights.medium);
      expect(weekText.style?.fontWeight, AppWeights.regular);

      await tester.tap(find.text('Week'));
      await tester.pump();

      expect(reported, 1);

      dayText = tester.widget<Text>(find.text('Day'));
      weekText = tester.widget<Text>(find.text('Week'));
      expect(dayText.style?.fontWeight, AppWeights.regular);
      expect(weekText.style?.fontWeight, AppWeights.medium);
    });

    testWidgets('a disabled option is dimmed and wires no tap handler', (
      tester,
    ) async {
      var reported = -1;
      await tester.pumpWidget(
        _wrap(
          AppSegmentedControl.inline(
            options: const [
              AppSegmentedOption(label: 'Inherit'),
              AppSegmentedOption(label: 'Allow', disabled: true),
              AppSegmentedOption(label: 'Deny'),
            ],
            selectedIndex: 0,
            onSegmentSelected: (i) => reported = i,
          ),
        ),
      );

      // Dimmed, so an unavailable choice reads as unavailable rather than as
      // an ordinary option that happens to do nothing.
      final allow = tester.widget<Text>(find.text('Allow'));
      final deny = tester.widget<Text>(find.text('Deny'));
      expect(allow.style?.color, AppTokens.light.textDisabled);
      expect(deny.style?.color, isNot(AppTokens.light.textDisabled));

      await tester.tap(find.text('Allow'));
      await tester.pump();
      expect(reported, -1, reason: 'a disabled option reports nothing');

      // The control still works, so the refusal is the option not the widget.
      await tester.tap(find.text('Deny'));
      await tester.pump();
      expect(reported, 2);
    });
  });

  group('AppSlider', () {
    testWidgets('reports value changes through onChanged', (tester) async {
      double? reported;

      await tester.pumpWidget(
        _wrap(SizedBox(
            width: 200,
            child: AppSlider(value: 20, onChanged: (v) => reported = v))),
      );

      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await tester.pump();

      expect(reported, isNotNull);
    });

    testWidgets('tall variant renders without a meter or ticks supplied',
        (tester) async {
      await tester.pumpWidget(_wrap(SizedBox(
          width: 200,
          child: AppSlider(value: 40, tall: true, onChanged: (_) {}))));

      expect(find.byType(AppSlider), findsOneWidget);
    });

    testWidgets('tall, muted, metered slider with ticks paints without error',
        (tester) async {
      // Every optional feature at once, because the custom paint code is this
      // widget's highest risk. See the library doc at the top of the file.
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 200,
            child: AppSlider(
              value: 65,
              tall: true,
              meter: 80,
              muted: true,
              ticks: const ['Quiet', 'Normal', 'Loud'],
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(AppSlider), findsOneWidget);
    });

    testWidgets('the tick nearest the thumb is the one picked out',
        (tester) async {
      const labels = ['Small', 'Default', 'Large'];
      final accent = AppTokens.light.accent;

      Future<List<String>> accented(double value) async {
        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 200,
              child: AppSlider(
                value: value,
                onChanged: (_) {},
                ticks: labels,
              ),
            ),
          ),
        );
        return [
          for (final label in labels)
            if (tester.widget<Text>(find.text(label)).style?.color == accent)
              label,
        ];
      }

      expect(await accented(0), ['Small']);
      expect(await accented(40), ['Default']);
      expect(await accented(50), ['Default']);
      expect(await accented(100), ['Large']);
    });
  });
}
