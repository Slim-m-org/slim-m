// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SettingsSectionCard`: the fix for the owner's "settings UI is very flat"
/// report (#39). A section's rows must sit inside a bordered `AppCard`, not
/// loose on the pane background, and the header above it must keep reading
/// as a real header rather than the card's own small uppercase title.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_hairline.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

/// The card's own box, as opposed to its header above it.
final _card = find.descendant(
  of: find.byType(SettingsSectionCard),
  matching: find.byType(ClipRRect),
);

void main() {
  testWidgets('wraps its rows in the card', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SettingsSectionCard(
          title: 'Devices',
          children: [Text('a phone')],
        ),
      ),
    );

    expect(
      find.descendant(of: _card, matching: find.text('a phone')),
      findsOneWidget,
      reason: 'the row must be inside the card, not a sibling of it',
    );
  });

  testWidgets('the header stays outside the card', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SettingsSectionCard(
          title: 'Devices',
          description: 'They are listed here.',
          children: [Text('a phone')],
        ),
      ),
    );

    expect(
      find.descendant(of: _card, matching: find.text('Devices')),
      findsNothing,
    );
    expect(find.byType(SettingsSectionHeader), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('They are listed here.')).dy,
      lessThan(tester.getTopLeft(_card).dy),
    );
  });

  testWidgets('adds no horizontal inset of its own, so the screen frame is '
      'the only thing that sets one', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SettingsSectionCard(
          title: 'Devices',
          children: [Text('a phone')],
        ),
      ),
    );

    final body = tester.getRect(find.byType(Scaffold));
    final card = tester.getRect(_card);
    expect(card.left, body.left, reason: 'decision 0013');
    expect(card.right, body.right);
    expect(
      tester.getRect(find.text('Devices')).left,
      card.left,
      reason: 'the header lines up with the card it names',
    );
  });

  testWidgets(
    'a description with no title asserts rather than silently dropping both',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          const SettingsSectionCard(
            description: 'Never rendered.',
            children: [Text('a phone')],
          ),
        ),
      );

      expect(tester.takeException(), isAssertionError);
    },
  );

  testWidgets('one hairline between each pair of rows, none at the edges', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const SettingsSectionCard(
          title: 'Display',
          children: [Text('a'), Text('b'), Text('c')],
        ),
      ),
    );
    final rules = find.byType(SettingsHairline);
    expect(rules, findsNWidgets(2));
    expect(
      tester.getRect(rules.first).width,
      tester.getRect(_card).width,
      reason: 'the rule runs the full width of the card',
    );
  });

  testWidgets('a row inside the card takes the card row metrics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const SettingsSectionCard(
          title: 'Display',
          children: [AppListRow(label: 'Clock')],
        ),
      ),
    );
    expect(tester.getSize(find.byType(AppListRow)).height, 56);
    expect(
      tester.getTopLeft(find.text('Clock')).dx - tester.getTopLeft(_card).dx,
      AppCardRowScope.inset,
    );
  });

  testWidgets('an untitled card starts as far down as a titled header', (
    tester,
  ) async {
    Future<double> cardTop(String? title) async {
      await tester.pumpWidget(
        _harness(
          SettingsSectionCard(title: title, children: const [Text('row')]),
        ),
      );
      return tester.getTopLeft(_card).dy;
    }

    final untitled = await cardTop(null);
    final titled = await cardTop('Display');
    expect(untitled, 28);
    expect(titled, greaterThan(untitled));
  });

  testWidgets('the card keeps its border over a child that fills its '
      'own background', (tester) async {
    final boundary = GlobalKey();
    const fill = Color(0xFFFF0000);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: boundary,
              child: const SizedBox(
                width: 200,
                child: SettingsSectionCard(
                  children: [
                    SizedBox(height: 80, child: ColoredBox(color: fill)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await render.toImage();
      final data = await image.toByteData();
      return (data!, image.width, image.height);
    });
    final (data, width, height) = bytes!;
    Color at(int x, int y) {
      final i = (y * width + x) * 4;
      return Color.fromARGB(
        data.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
    }

    final origin = tester.getTopLeft(find.byKey(boundary));
    final child = tester
        .getRect(
          find.byWidgetPredicate((w) => w is ColoredBox && w.color == fill),
        )
        .shift(-origin);
    final midY = child.center.dy.round();
    final midX = child.center.dx.round();
    expect(at(0, midY), AppTokens.dark.borderSubtle, reason: 'left edge');
    expect(at(width - 1, midY), AppTokens.dark.borderSubtle, reason: 'right');
    expect(
      at(midX, child.bottom.round() - 1),
      AppTokens.dark.borderSubtle,
      reason: 'bottom edge, painted over the child',
    );
    expect(at(midX, midY), fill, reason: 'the child still fills inside');
  });
}
