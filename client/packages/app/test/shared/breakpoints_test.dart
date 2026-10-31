// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `LayoutClass`'s width-driven decisions: which of the three
/// classes a width lands in, and whether a docked member pane fits.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('the three classes land where the design expects', () {
    expect(LayoutClass.fromWidth(599), LayoutClass.compact);
    expect(LayoutClass.fromWidth(600), LayoutClass.medium);
    expect(LayoutClass.fromWidth(999), LayoutClass.medium);
    expect(LayoutClass.fromWidth(1000), LayoutClass.expanded);
  });

  group('fitsMemberPane', () {
    // The width fitsMemberPane's own doc comment derives it from.
    const minTranscript =
        kCompactWidth - ChannelRail.mediumWidth - AppSizes.rowPointer;
    const mediumThreshold =
        ChannelRail.mediumWidth +
        AppSizes.rowPointer +
        AppMemberPane.width +
        minTranscript;

    test('never fits at compact, however wide the window', () {
      expect(LayoutClass.compact.fitsMemberPane(4000), isFalse);
    });

    test('medium is one pixel too narrow just below the threshold', () {
      expect(LayoutClass.medium.fitsMemberPane(mediumThreshold - 1), isFalse);
    });

    test('medium has room right at the threshold', () {
      expect(LayoutClass.medium.fitsMemberPane(mediumThreshold), isTrue);
    });

    test('the owner\'s reported half-desktop width (955px) has room', () {
      expect(LayoutClass.medium.fitsMemberPane(955), isTrue);
    });

    test('medium at 700, the width the shell tests already pump, has none', () {
      expect(LayoutClass.medium.fitsMemberPane(700), isFalse);
    });

    test('expanded always fits, since it starts above its own threshold', () {
      expect(LayoutClass.expanded.fitsMemberPane(1000), isTrue);
    });
  });
}
