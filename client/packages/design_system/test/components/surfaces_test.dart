// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child, {AppTokens? tokens}) {
  final t = tokens ?? AppTokens.light;
  return tester.pumpWidget(
    MaterialApp(
        theme: buildTheme(Brightness.light, t),
        home: Scaffold(body: Center(child: child))),
  );
}

/// Maps each leaf [TextSpan]'s literal text to the colour it painted with,
/// walked recursively so a regression that flattens spans back into one style
/// cannot hide from it.
Map<String, Color> _spanColorsByText(InlineSpan root) {
  final byText = <String, Color>{};
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      final text = span.text;
      final color = span.style?.color;
      if (text != null && color != null) byText[text] = color;
      span.children?.forEach(visit);
    }
  }

  visit(root);
  return byText;
}

/// Whether a focus-ring outline (the keyboard-focus cue, distinct from the
/// accent-tinted selection fill) is present anywhere in the tree.
bool _hasFocusRing(WidgetTester tester, Color focusRing) {
  return tester.any(
    find.byWidgetPredicate(
      (w) =>
          w is Container &&
          (w.foregroundDecoration as BoxDecoration?)?.border?.top.color ==
              focusRing,
    ),
  );
}

void main() {
  group('AppListRow', () {
    testWidgets('selected shows a left accent marker and a tinted fill',
        (tester) async {
      const tokens = AppTokens.light;

      await _pump(
        tester,
        const SizedBox(
            width: 240, child: AppListRow(label: 'general', selected: true)),
      );
      expect(find.byKey(AppListRow.selectionMarkerKey), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color == tokens.accentSoft,
        ),
        findsOneWidget,
        reason: 'selected row must fill with accentSoft, not an ad-hoc colour',
      );

      await _pump(tester,
          const SizedBox(width: 240, child: AppListRow(label: 'general')));
      expect(
        find.byKey(AppListRow.selectionMarkerKey),
        findsNothing,
        reason: 'an unselected row must not carry the selection marker',
      );
    });

    testWidgets(
        'unread is signalled by a dot and a heavier weight, not colour alone', (
      tester,
    ) async {
      await _pump(tester,
          const SizedBox(width: 240, child: AppListRow(label: 'general')));
      final plainStyle = tester.widget<Text>(find.text('general')).style!;
      expect(find.byKey(AppListRow.unreadDotKey), findsNothing);

      await _pump(
        tester,
        const SizedBox(
            width: 240, child: AppListRow(label: 'general', unread: true)),
      );
      final unreadStyle = tester.widget<Text>(find.text('general')).style!;

      // Two independent, non-colour cues: the dot appears and the label's
      // weight changes. Either alone leaves a colour-only reading possible.
      expect(find.byKey(AppListRow.unreadDotKey), findsOneWidget);
      expect(
        unreadStyle.fontWeight,
        isNot(plainStyle.fontWeight),
        reason: 'unread must change weight, not just colour',
      );
      expect(unreadStyle.fontWeight, AppWeights.medium);
    });

    testWidgets('the unread dot is suppressed when trailing content is present',
        (tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 240,
          child:
              AppListRow(label: 'general', unread: true, trailing: Text('2')),
        ),
      );
      expect(
        find.byKey(AppListRow.unreadDotKey),
        findsNothing,
        reason:
            'a trailing badge already carries the unread meaning; the dot would be redundant',
      );
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('muted dims the trailing content but never the label',
        (tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 240,
          child: AppListRow(
            label: 'general',
            muted: true,
            leading: Icon(Icons.tag),
            trailing: Text('3'),
          ),
        ),
      );
      // The label stays at full strength: textSecondary is already near the
      // AA floor, and dimming the whole row dragged names below it.
      expect(
        find.ancestor(of: find.text('general'), matching: find.byType(Opacity)),
        findsNothing,
      );
      // The de-emphasis lives on the leading and trailing content instead.
      for (final finder in [find.byIcon(Icons.tag), find.text('3')]) {
        final opacity = tester.widget<Opacity>(
          find.ancestor(of: finder, matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 0.62);
      }
      // Muted must not borrow textDisabled ("not actionable"): a muted row is
      // still fully actionable, just de-emphasised.
      expect(
        tester.widget<Text>(find.text('general')).style!.color,
        isNot(AppTokens.light.textDisabled),
      );
    });

    testWidgets(
        'an optional meta caption renders in text-secondary regardless of state',
        (
      tester,
    ) async {
      await _pump(
        tester,
        const SizedBox(
          width: 240,
          child: AppListRow(
              label: 'general', selected: true, unread: true, meta: '2m'),
        ),
      );
      expect(
        tester.widget<Text>(find.text('2m')).style!.color,
        AppTokens.light.textSecondary,
      );
    });

    testWidgets('touch raises the row to rowTouch; pointer stays at rowPointer',
        (tester) async {
      await _pump(
        tester,
        const SizedBox(
            width: 240, child: AppListRow(label: 'general', touch: true)),
      );
      expect(tester.getSize(find.byType(AppListRow)).height, AppSizes.rowTouch);

      await _pump(tester,
          const SizedBox(width: 240, child: AppListRow(label: 'general')));
      expect(
          tester.getSize(find.byType(AppListRow)).height, AppSizes.rowPointer);
    });

    testWidgets(
        'grows past rowPointer once Dynamic Type scales the label past what '
        'the fixed height can hold', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2.0)),
              child: const Scaffold(
                body: Center(
                  child:
                      SizedBox(width: 240, child: AppListRow(label: 'general')),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(AppListRow)).height,
        greaterThan(AppSizes.rowPointer),
        reason: 'the label at 2x Dynamic Type no longer fits rowPointer',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'a row that clips instead of growing overflows silently',
      );
    });

    testWidgets(
        'a subtitle grows the row as one cohesive, tappable cell; without one '
        'the row is unchanged', (tester) async {
      await _pump(
        tester,
        const SizedBox(width: 240, child: AppListRow(label: 'general')),
      );
      expect(
          tester.getSize(find.byType(AppListRow)).height, AppSizes.rowPointer);
      expect(find.byType(Column), findsNothing);

      var tapped = false;
      await _pump(
        tester,
        SizedBox(
          width: 240,
          child: AppListRow(
            label: 'Priya',
            subtitle: 'in a meeting',
            onTap: () => tapped = true,
          ),
        ),
      );
      expect(find.text('Priya'), findsOneWidget);
      expect(find.text('in a meeting'), findsOneWidget);
      expect(tester.getSize(find.byType(AppListRow)).height,
          greaterThan(AppSizes.rowPointer));

      // One cohesive cell: a single tap fires onTap, not a separate untappable block.
      await tester.tap(find.byType(AppListRow));
      expect(tapped, isTrue);
    });

    testWidgets(
        'selected, unread and focused combine without any pair becoming ambiguous',
        (
      tester,
    ) async {
      const tokens = AppTokens.light;
      final focusNode = FocusNode(debugLabel: 'row');
      addTearDown(focusNode.dispose);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic);

      await _pump(
        tester,
        SizedBox(
          width: 240,
          child: AppListRow(
            label: 'general',
            selected: true,
            unread: true,
            onTap: () {},
            focusNode: focusNode,
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      await tester.pump();

      // Selection's cue (the left marker) is present.
      expect(find.byKey(AppListRow.selectionMarkerKey), findsOneWidget);
      // Unread's cue (the dot, since there is no trailing widget) is present
      // alongside selection, not swallowed by it.
      expect(find.byKey(AppListRow.unreadDotKey), findsOneWidget);
      // Focus's cue (the outline ring) is present alongside both, even though
      // focusRing and accent share a hex in every theme: shape keeps them apart.
      expect(_hasFocusRing(tester, tokens.focusRing), isTrue);
    });
  });

  group('AppCallout', () {
    testWidgets('each tone renders its own icon, not just its own colour',
        (tester) async {
      await _pump(
        tester,
        const Column(
          children: [
            AppCallout(tone: AppCalloutTone.warn, child: Text('m')),
            AppCallout(tone: AppCalloutTone.info, child: Text('m')),
            AppCallout(tone: AppCalloutTone.accent, child: Text('m')),
          ],
        ),
      );

      expect(find.byIcon(AppIcons.warning), findsOneWidget);
      expect(find.byIcon(AppIcons.info), findsOneWidget);
      expect(find.byIcon(AppIcons.highlight), findsOneWidget);
    });

    testWidgets(
        'the accent tone borders with accentFill, a legitimate use of the closed list',
        (
      tester,
    ) async {
      const tokens = AppTokens.light;
      await _pump(
        tester,
        const AppCallout(tone: AppCalloutTone.accent, child: Text('m')),
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.border?.top.color ==
                  tokens.accentFill,
        ),
        findsOneWidget,
      );
    });
  });

  group('AppCodeBlock', () {
    testWidgets('colours each syntax role from AppCodeColors, not a literal',
        (tester) async {
      const tokens = AppTokens.light;

      await _pump(
        tester,
        const AppCodeBlock(
          lines: [
            AppCodeLine([
              AppCodeSpan('let', AppCodeRole.keyword),
              AppCodeSpan(' x = ', AppCodeRole.plain),
              AppCodeSpan('1', AppCodeRole.number),
              AppCodeSpan(' // c', AppCodeRole.comment),
            ]),
          ],
        ),
        tokens: tokens,
      );

      // Merge every RichText under the block (header language label, body)
      // rather than assuming tree order, so lookup ignores which comes first.
      final byText = <String, Color>{};
      for (final richText in tester.widgetList<RichText>(
        find.descendant(
            of: find.byType(AppCodeBlock), matching: find.byType(RichText)),
      )) {
        byText.addAll(_spanColorsByText(richText.text));
      }

      // Each span's colour must trace to the matching AppCodeColors role, not a
      // literal: assert exact (text, role) pairs, not "some colour appeared".
      expect(byText['let'], tokens.code.keyword);
      expect(byText['1'], tokens.code.number);
      expect(byText[' // c'], tokens.code.comment);
      // The plain span must not have been coloured as if it were a role: it
      // takes the ordinary text colour, not one of the five syntax hues.
      expect(byText[' x = '], tokens.textPrimary);
      expect(byText[' x = '], isNot(tokens.code.keyword));
    });

    testWidgets(
        'the header renders the language and the caller-supplied action slot', (
      tester,
    ) async {
      await _pump(
        tester,
        AppCodeBlock(
          language: 'dart',
          action: const Icon(Icons.copy, key: Key('caller-action')),
          lines: [AppCodeLine.plain('x')],
        ),
      );
      expect(find.text('dart'), findsOneWidget);
      expect(find.byKey(const Key('caller-action')), findsOneWidget);
    });
  });

  group('AppCard', () {
    testWidgets('an optional title header renders uppercased', (tester) async {
      await _pump(
        tester,
        const AppCard(title: 'Danger zone', child: Text('content')),
      );
      expect(find.text('DANGER ZONE'), findsOneWidget);
      expect(find.text('content'), findsOneWidget);
    });

    testWidgets('no title renders no header', (tester) async {
      await _pump(tester, const AppCard(child: Text('content')));
      expect(find.text('CONTENT'), findsNothing);
      expect(find.text('content'), findsOneWidget);
    });
  });

  group('AppMenu', () {
    testWidgets(
        'items fire onTap, and a danger-tone item colours from dangerText', (
      tester,
    ) async {
      const tokens = AppTokens.light;
      var tapped = false;

      await _pump(
        tester,
        AppMenu(
          children: [
            AppMenuItem(label: 'Rename', onTap: () {}),
            AppMenuItem(
              label: 'Delete',
              tone: AppMenuItemTone.danger,
              onTap: () => tapped = true,
            ),
          ],
        ),
      );

      await tester.tap(find.text('Delete'));
      expect(tapped, isTrue);
      expect(tester.widget<Text>(find.text('Delete')).style!.color,
          tokens.dangerText);
    });

    testWidgets(
        'touch raises MenuItem height and a submenu item shows a chevron',
        (tester) async {
      await _pump(
        tester,
        AppMenu(children: [
          AppMenuItem(label: 'Share', submenu: true, touch: true, onTap: () {})
        ]),
      );
      expect(
        tester.getSize(find.byType(AppMenuItem)).height,
        AppSizes.rowTouchMenu,
      );
      expect(find.byIcon(AppIcons.chevronRight), findsOneWidget);
    });

    testWidgets('AppMenuLabel uppercases its text', (tester) async {
      await _pump(tester, const AppMenuLabel('channel'));
      expect(find.text('CHANNEL'), findsOneWidget);
    });

    testWidgets('the outer edge is borderStrong, not borderSubtle',
        (tester) async {
      // borderStrong's own doc names this exact case, and drawing it in
      // borderSubtle left the token referenced by no widget at all.
      const tokens = AppTokens.dark;
      await _pump(
        tester,
        AppMenu(children: [AppMenuItem(label: 'Rename', onTap: () {})]),
        tokens: tokens,
      );

      final edge = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(AppMenu),
            matching: find.byType(Container),
          ))
          .map((c) =>
              (c.foregroundDecoration as BoxDecoration?)?.border?.top.color)
          .whereType<Color>();

      expect(edge, contains(tokens.borderStrong));
      expect(edge, isNot(contains(tokens.borderSubtle)));
    });
  });
}
