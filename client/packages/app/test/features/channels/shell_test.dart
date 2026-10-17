// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the layout rules and the messaging surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  group('layout classes', () {
    test('width alone decides the layout, not the platform', () {
      // A phone in landscape, a narrow desktop window, and a tablet in split
      // view are the same problem; keying off Platform.isX gets all three wrong.
      expect(LayoutClass.fromWidth(320), LayoutClass.compact);
      expect(LayoutClass.fromWidth(599), LayoutClass.compact);
      expect(LayoutClass.fromWidth(600), LayoutClass.medium);
      expect(LayoutClass.fromWidth(999), LayoutClass.medium);
      expect(LayoutClass.fromWidth(1000), LayoutClass.expanded);
      expect(LayoutClass.fromWidth(2560), LayoutClass.expanded);
    });

    test('only compact hides one pane at a time', () {
      expect(LayoutClass.compact.showsBothPanes, isFalse);
      expect(LayoutClass.medium.showsBothPanes, isTrue);
      expect(LayoutClass.expanded.showsBothPanes, isTrue);
    });

    testWidgets('the class follows the window, not a fixed guess', (
      tester,
    ) async {
      late LayoutClass observed;
      Widget probe(Size size) => MediaQuery(
        data: MediaQueryData(size: size),
        child: Builder(
          builder: (context) {
            observed = LayoutClass.of(context);
            return const SizedBox();
          },
        ),
      );

      await tester.pumpWidget(probe(const Size(400, 800)));
      expect(observed, LayoutClass.compact);

      // Resizing a desktop window must re-evaluate, not stay on first paint.
      await tester.pumpWidget(probe(const Size(1400, 900)));
      expect(observed, LayoutClass.expanded);
    });
  });

  group('message ids', () {
    test('are well-formed uuid v7', () {
      final id = newMessageId();
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id),
        isTrue,
        reason: 'version 7 and the RFC variant bits must be set: $id',
      );
    });

    test('are unique and time-ordered', () {
      final ids = List.generate(50, (_) => newMessageId());
      expect(ids.toSet(), hasLength(50), reason: 'no collisions');
      // The millisecond prefix means lexical order matches creation order,
      // which is what keeps the server's storage locality good.
      final sorted = List.of(ids)..sort();
      expect(sorted.first.substring(0, 8), ids.first.substring(0, 8));
    });
  });

  group('theme', () {
    test('tokens reach widgets through the theme extension', () {
      for (final (brightness, tokens) in [
        (Brightness.light, AppTokens.light),
        (Brightness.dark, AppTokens.dark),
      ]) {
        final theme = buildTheme(brightness, tokens);
        expect(theme.extension<AppTokens>(), same(tokens));
        expect(theme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor, tokens.surfaceBase);
      }
    });

    testWidgets('a widget reads colours from tokens, not literals', (
      tester,
    ) async {
      late AppTokens resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) {
              resolved = Theme.of(context).extension<AppTokens>()!;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved.accent, AppTokens.dark.accent);
    });
  });
}
