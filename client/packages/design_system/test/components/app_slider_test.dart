// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Widget tests for AppSlider, split from forms_test.dart.
///
/// The slider's "tall, muted, metered with ticks" case exists because the custom
/// track and thumb paint code is the newest, highest-risk part of that widget.
/// It exercises every optional feature at once so a bad rect (for example a
/// meter fraction that clips negative) surfaces here rather than the first time
/// a caller combines them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_design_system/src/components/forms/slider_shapes.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
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

    testWidgets('a divided slider draws no tick marks on its trough',
        (tester) async {
      await tester.pumpWidget(_wrap(SizedBox(
          width: 200,
          child:
              AppSlider(value: 4, max: 16, divisions: 4, onChanged: (_) {}))));

      final theme = SliderTheme.of(tester.element(find.byType(Slider)));
      expect(theme.tickMarkShape, SliderTickMarkShape.noTickMark);
    });

    testWidgets('an inactive meter is drawn in a neutral tone', (tester) async {
      Future<Color> meterColor({required bool active}) async {
        await tester.pumpWidget(_wrap(SizedBox(
            width: 200,
            child: AppSlider(
                value: 40,
                tall: true,
                meter: 60,
                meterActive: active,
                onChanged: (_) {}))));
        final theme = SliderTheme.of(tester.element(find.byType(Slider)));
        return (theme.trackShape! as TroughTrackShape).meterColor;
      }

      expect(await meterColor(active: true),
          isNot(await meterColor(active: false)));
    });

    testWidgets('an inactive meter uses the disabled tone, not the edge token',
        (tester) async {
      await tester.pumpWidget(_wrap(SizedBox(
          width: 200,
          child: AppSlider(
              value: 40,
              tall: true,
              meter: 60,
              meterActive: false,
              onChanged: (_) {}))));
      final tokens =
          Theme.of(tester.element(find.byType(Slider))).extension<AppTokens>()!;
      final theme = SliderTheme.of(tester.element(find.byType(Slider)));
      final color = (theme.trackShape! as TroughTrackShape).meterColor;
      expect(color, tokens.textDisabled.withValues(alpha: inactiveMeterAlpha));
      expect(color, isNot(tokens.borderStrong));
    });

    for (final (name, tokens) in [
      ('light', AppTokens.light),
      ('dark', AppTokens.dark),
      ('true black', AppTokens.trueBlack),
      ('mocha', AppTokens.mocha),
      ('soft', AppTokens.soft),
      ('forest', AppTokens.forest),
    ]) {
      test('$name: a live meter is visible and outweighs a silenced one', () {
        final trough = tokens.surfaceSunken;
        Color over(Color c) => Color.alphaBlend(c, trough);
        final live = contrastRatio(
          over(tokens.accentFill.withValues(alpha: activeMeterAlpha)),
          trough,
        );
        final silenced = contrastRatio(
          over(tokens.textDisabled.withValues(alpha: inactiveMeterAlpha)),
          trough,
        );
        expect(live, greaterThanOrEqualTo(2.4));
        expect(live, greaterThan(silenced * 1.3));
      });
    }

    testWidgets('a muted inactive meter is not dimmed twice', (tester) async {
      await tester.pumpWidget(_wrap(SizedBox(
          width: 200,
          child: AppSlider(
              value: 40,
              tall: true,
              meter: 60,
              meterActive: false,
              muted: true,
              onChanged: (_) {}))));
      final tokens =
          Theme.of(tester.element(find.byType(Slider))).extension<AppTokens>()!;
      final theme = SliderTheme.of(tester.element(find.byType(Slider)));
      expect((theme.trackShape! as TroughTrackShape).meterColor,
          tokens.textSecondary);
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
      // Every optional feature at once; see the library doc for why.
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

    group('value bubble', () {
      Widget slider() => _wrap(
            SizedBox(
              width: 300,
              child: AppSlider(
                value: -50,
                min: -80,
                max: 0,
                tall: true,
                splitTrack: true,
                valueLabel: (v) => '${v.round()} dB',
                onChanged: (_) {},
              ),
            ),
          );

      testWidgets('is hidden at rest and shown while dragging the thumb',
          (tester) async {
        await tester.pumpWidget(slider());
        expect(find.text('-50 dB'), findsNothing);

        final thumb = tester.getCenter(find.byType(Slider));
        final gesture = await tester.startGesture(thumb);
        await tester.pump();
        expect(find.text('-50 dB'), findsOneWidget);

        await gesture.up();
        await tester.pump();
        expect(find.text('-50 dB'), findsNothing);
      });

      testWidgets('is shown on keyboard focus', (tester) async {
        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 300,
              child: AppSlider(
                value: -50,
                min: -80,
                max: 0,
                autofocus: true,
                valueLabel: (v) => '${v.round()} dB',
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('-50 dB'), findsOneWidget);
      });

      testWidgets('keeps the number for screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(slider());
        final tree = tester.getSemantics(find.byType(Slider)).toStringDeep();
        expect(tree, contains('value: "-50 dB"'));
        handle.dispose();
      });
    });
  });
}
