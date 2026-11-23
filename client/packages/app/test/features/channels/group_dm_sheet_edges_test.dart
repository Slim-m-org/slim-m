// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The group DM sheets put the title, section labels and member avatars on
/// one left edge, and the search icon is the shared 16dp size.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_fonts.dart';
import 'group_dm_harness.dart';

Finder _avatarIn(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byWidgetPredicate((w) => w is UserAvatar),
);

void main() {
  setUpAll(loadRealFonts);
  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('members sheet shares one left edge at ${size.width}', (
      tester,
    ) async {
      await openMembersSheet(tester, size: size);

      final title = tester
          .getTopLeft(find.text('Person1 and Person2').first)
          .dx;
      final count = tester.getTopLeft(find.text('3 of 10 people')).dx;
      final add = tester.getTopLeft(find.text('Add someone')).dx;
      final member = tester.getTopLeft(_avatarIn('group-dm-member:u1')).dx;
      final person = tester.getTopLeft(_avatarIn('group-dm-person:u3')).dx;

      expect(count, closeTo(title, 0.01));
      expect(add, closeTo(title, 0.01));
      expect(member, closeTo(title, 0.01));
      expect(person, closeTo(title, 0.01));
      expect(
        tester.getSize(find.byIcon(AppIcons.search)).width,
        lessThanOrEqualTo(AppSizes.icon16),
      );
    });
  }

  testWidgets('the delete confirm names its action in full at 390', (
    tester,
  ) async {
    await openMembersSheet(tester, size: const Size(390, 844));
    await tester.ensureVisible(find.text('Delete group'));
    await tester.tap(find.text('Delete group'));
    await tester.pump(const Duration(seconds: 1));

    final action = tester.renderObject<RenderParagraph>(
      find.text('Delete group'),
    );
    expect(action.didExceedMaxLines, isFalse);
  });
}
