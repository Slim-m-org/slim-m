// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Left the Space" notice keeps a gap above the composer instead of
/// touching its border.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/dm_departure.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_departure_notice.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('the notice leaves a gap below it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Column(
            children: [
              DmDepartureNotice(departure: DmDeparture.left),
              SizedBox(key: Key('composer'), height: 40),
            ],
          ),
        ),
      ),
    );

    final notice = tester.getRect(find.text(DmDeparture.left.notice));
    final callout = tester.getRect(
      find.ancestor(
        of: find.text(DmDeparture.left.notice),
        matching: find.byWidgetPredicate((w) => w is AppCallout),
      ),
    );
    expect(notice.bottom, lessThanOrEqualTo(callout.bottom));
    expect(
      tester.getTopLeft(find.byKey(const Key('composer'))).dy - callout.bottom,
      greaterThanOrEqualTo(AppSpacing.s8),
    );
  });
}
