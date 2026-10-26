// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One banner shape on every surface, so the crop a person frames is the crop everyone sees.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/profile_banner.dart';
import 'package:slimm_design_system/design_system.dart';

Future<Size> _bannerAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: ProfileBanner(
            userId: 'u',
            bannerUpdatedAt: null,
            colour: Color(0xFF336699),
          ),
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(ProfileBanner));
}

void main() {
  for (final width in [300.0, 390.0, 640.0]) {
    testWidgets('the banner keeps its shape at $width wide', (tester) async {
      final size = await _bannerAt(tester, width);

      expect(size.width / size.height, closeTo(kProfileBannerAspect, 0.01));
    });
  }

  testWidgets('the popover width still gets the old 56 high band', (
    tester,
  ) async {
    final size = await _bannerAt(tester, 300);

    expect(size.height, closeTo(56, 0.5));
  });
}
