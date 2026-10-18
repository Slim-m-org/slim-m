// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The welcome step looks finished with or without an icon, a description and
/// a banner, and shows the banner the invite landing card carries.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/space_banner.dart';

import 'first_run_harness.dart';

void main() {
  testWidgets('a bare Space gets a monogram tile beside its name', (
    tester,
  ) async {
    await pumpFirstRun(tester, description: false, inviter: 'Grace');
    final tile = find.text('L');
    expect(tile, findsOneWidget);
    final name = find.text('Lamplight');
    // One row: tile left of the name, both centred on the same line.
    expect(
      tester.getCenter(tile).dy,
      moreOrLessEquals(
        (tester.getTopLeft(name).dy +
                tester.getBottomLeft(find.text('Grace invited you.')).dy) /
            2,
        epsilon: 2,
      ),
    );
    expect(tester.getTopRight(tile).dx, lessThan(tester.getTopLeft(name).dx));
    expect(find.byType(SpaceBanner), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no description leaves no gap before the closing line', (
    tester,
  ) async {
    await pumpFirstRun(tester, description: false);
    final gap =
        tester.getTopLeft(find.textContaining('A few quick choices')).dy -
        tester.getBottomLeft(find.text('Lamplight')).dy;
    expect(gap, lessThan(40));
  });

  testWidgets('a set banner shows above the name, full width', (tester) async {
    await pumpFirstRun(tester, banner: tinyPng);
    final image = find.byType(Image);
    expect(image, findsOneWidget);
    expect(
      tester.getBottomLeft(image).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('Lamplight')).dy),
    );
    final step = tester.getRect(find.byType(SpaceBanner));
    expect(step.width / step.height, moreOrLessEquals(3, epsilon: 0.05));
  });

  testWidgets('a set icon replaces the monogram', (tester) async {
    await pumpFirstRun(tester, icon: true);
    expect(find.text('L'), findsNothing);
  });
}
