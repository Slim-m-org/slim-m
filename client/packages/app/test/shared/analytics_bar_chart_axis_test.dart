// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AnalyticsBarChart]'s axis: the part that turned three shapes into three
/// readable charts.
///
/// Before this existed a reader could see the outline and answer no question
/// with it - not which hour a tall bar was, not what the scale reached. The
/// cases worth holding are the ones that quietly stop being true: a tick
/// landing under the wrong bar, and an axis that overprints itself instead of
/// thinning when the width runs out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/analytics_bar_chart.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  required List<double> values,
  Map<int, String> ticks = const {},
  String? maxLabel,
  double width = 600,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: AnalyticsBarChart(
              values: values,
              semanticsLabel: 'series',
              ticks: ticks,
              maxLabel: maxLabel,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Twenty-four hours of traffic, so the hour ticks have something to sit under.
List<double> get _day => List<double>.generate(24, (i) => (i * 3).toDouble());

void main() {
  testWidgets('states the scale it was given', (tester) async {
    await _pump(tester, values: _day, maxLabel: '415');

    expect(find.text('415'), findsOneWidget);
  });

  testWidgets('draws no scale when the caller has none to state', (
    tester,
  ) async {
    await _pump(tester, values: _day);

    expect(find.text('415'), findsNothing);
  });

  testWidgets('every hour landmark is labelled at a comfortable width', (
    tester,
  ) async {
    await _pump(
      tester,
      values: _day,
      ticks: const {0: '00', 6: '06', 12: '12', 18: '18'},
    );

    for (final hour in const ['00', '06', '12', '18']) {
      expect(find.text(hour), findsOneWidget);
    }
  });

  testWidgets('a tick sits under the bar it names, not evenly spaced', (
    tester,
  ) async {
    await _pump(
      tester,
      values: _day,
      ticks: const {0: '00', 6: '06', 12: '12', 18: '18'},
    );

    // 24 bars across 600px is 25px each, so hour 12 centres near 312px.
    final twelve = tester.getCenter(find.text('12')).dx;
    final zero = tester.getCenter(find.text('00')).dx;
    expect(
      twelve - zero,
      closeTo(300, 40),
      reason:
          'an evenly-spaced row would put the third of four labels at two '
          'thirds of the width; it has to track its own bar instead',
    );
  });

  testWidgets('short labels are not thinned when they genuinely fit', (
    tester,
  ) async {
    // They measure well inside 300px, so thinning would drop a usable landmark.
    await _pump(
      tester,
      values: _day,
      ticks: const {0: '00', 6: '06', 12: '12', 18: '18'},
      width: 300,
    );

    for (final hour in const ['00', '06', '12', '18']) {
      expect(find.text(hour), findsOneWidget);
    }
  });

  testWidgets('a narrow width thins the axis rather than overprinting it', (
    tester,
  ) async {
    // Three five-character dates cannot fit in 90px: the 30-day chart on a phone.
    await _pump(
      tester,
      values: List<double>.generate(30, (i) => i.toDouble()),
      ticks: const {0: '07-01', 15: '07-16', 29: '07-30'},
      width: 90,
    );

    final shown = [
      for (final date in const ['07-01', '07-16', '07-30'])
        if (find.text(date).evaluate().isNotEmpty) date,
    ];
    expect(
      shown.length,
      lessThan(3),
      reason: '90px cannot hold three dates without them colliding',
    );
    expect(
      shown,
      isNotEmpty,
      reason: 'thinning must leave a landmark, not clear the axis',
    );
    expect(
      shown.first,
      '07-01',
      reason: 'the series should stay bounded at its start',
    );
  });

  testWidgets('an edge label stays inside the chart', (tester) async {
    await _pump(tester, values: _day, ticks: const {23: '23'}, width: 300);

    // Both rects are global, so compare against the chart's bounds, not width.
    final chart = tester.getRect(find.byType(AnalyticsBarChart));
    final label = tester.getRect(find.text('23'));
    expect(
      label.right,
      lessThanOrEqualTo(chart.right + 1),
      reason: 'the last bar is at the right edge; its label must not hang off',
    );
    expect(label.left, greaterThanOrEqualTo(chart.left - 1));
  });

  testWidgets('an empty series draws no axis at all', (tester) async {
    await _pump(tester, values: const [], ticks: const {0: '00'});

    expect(find.text('00'), findsNothing);
  });

  testWidgets('the series stays readable to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      values: _day,
      ticks: const {0: '00', 12: '12'},
      maxLabel: '415',
    );

    // The series is one label; announcing ticks too reads as loose numbers.
    expect(find.bySemanticsLabel('series'), findsOneWidget);
    expect(find.bySemanticsLabel('00'), findsNothing);
    expect(find.bySemanticsLabel('415'), findsNothing);
    handle.dispose();
  });
}
