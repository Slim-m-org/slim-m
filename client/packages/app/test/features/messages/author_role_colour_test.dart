// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message author's name wears their highest coloured role's colour, kept
/// readable on the transcript, the default colour without one, and follows a
/// role change while the row stays on screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

api.UserProfile _author(List<int?> colours) => api.UserProfile(
  id: 'u1',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  roles: [for (var i = 0; i < colours.length; i++) 'role $i'],
  roleIds: [for (var i = 0; i < colours.length; i++) 'r-$i'],
  roleColors: colours,
);

Future<BatchProfilesController> _pump(
  WidgetTester tester,
  api.UserProfile author,
) async {
  late BatchProfilesController controller;
  await tester.pumpWidget(
    harness(
      MessageRow(
        message: message(authorId: author.id),
        grouped: false,
        showNewDivider: false,
        knownUsernames: const {},
        actions: noActions,
        editing: false,
        callbacks: MessageRowCallbacks(
          onRetry: () {},
          onDiscard: () {},
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: (_) {},
          onCancelEdit: () {},
        ),
      ),
      overrides: [
        batchProfilesControllerProvider.overrideWith((ref) {
          controller = BatchProfilesController(ref);
          return controller;
        }),
      ],
    ),
  );
  controller.state = {...controller.state, author.id: author};
  await tester.pump();
  return controller;
}

Color? _nameColour(WidgetTester tester) =>
    tester.widget<Text>(find.text('Ada')).style?.color;

void main() {
  testWidgets('the name wears the top coloured role, readable', (tester) async {
    await _pump(tester, _author(const [null, 0, 6]));

    final colour = _nameColour(tester)!;
    expect(
      HSLColor.fromColor(colour).hue,
      closeTo(HSLColor.fromColor(rolePalette[0].color).hue, 1),
    );
    expect(
      contrastRatio(colour, AppTokens.light.surfaceBase),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('no coloured role keeps the default author colour', (
    tester,
  ) async {
    await _pump(tester, _author(const [null]));
    expect(_nameColour(tester), AppTokens.light.textPrimary);
  });

  testWidgets('a role change repaints the name in place', (tester) async {
    final controller = await _pump(tester, _author(const [1]));
    final before = _nameColour(tester);

    controller.state = {
      ...controller.state,
      'u1': _author(const [6]),
    };
    await tester.pump();

    expect(_nameColour(tester), isNot(before));
    expect(
      HSLColor.fromColor(_nameColour(tester)!).hue,
      closeTo(HSLColor.fromColor(rolePalette[6].color).hue, 1),
    );
  });
}
