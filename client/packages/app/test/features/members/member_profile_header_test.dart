// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile card's header: what a screen reader hears from the avatar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_sections.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/call_header_fixture.dart' show FakePresence;

api.UserProfile _profile(String displayName) => api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: displayName,
  createdAt: 1788000000000,
);

Future<void> _pump(
  WidgetTester tester,
  api.UserProfile profile, {
  bool inCallTogether = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        presenceControllerProvider.overrideWith(
          (ref) => FakePresence(ref, {profile.id: api.PresenceState.dnd}),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MemberProfileHeader(
              profile: profile,
              isSelf: false,
              inCallTogether: inCallTogether,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('in a call together the avatar still says their presence', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _profile('Maya Chen'), inCallTogether: true);

    final label = tester
        .getSemantics(find.bySemanticsLabel(RegExp('^Maya Chen, ')))
        .label;
    expect(label, contains('in a call with you'));
    expect(label, contains('do not disturb'));
    semantics.dispose();
  });
}
