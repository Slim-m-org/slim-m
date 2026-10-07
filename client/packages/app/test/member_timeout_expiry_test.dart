// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/call_header_fixture.dart' show FakePresence;

api.UserProfile _profile(int until) => api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  roles: const ['mod'],
  roleIds: const ['role-mod'],
  timedOutUntil: until,
);

Widget _harness(Widget child) => ProviderScope(
  overrides: [
    presenceControllerProvider.overrideWith(
      (ref) => FakePresence(ref, const {'user-maya': api.PresenceState.online}),
    ),
    myPermissionsProvider.overrideWithValue(Perm.kickMembers),
    membersProvider.overrideWith((ref) async => const <api.UserProfile>[]),
    rolesProvider.overrideWith((ref) async => const <api.Role>[]),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Future<void> _pastDeadline(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1600)),
  );
  await tester.pump(const Duration(seconds: 2));
}

int _deadlineIn(Duration d) => DateTime.now().add(d).millisecondsSinceEpoch;

void main() {
  testWidgets('the timed out badge goes when the deadline passes', (
    tester,
  ) async {
    final profile = _profile(_deadlineIn(const Duration(milliseconds: 1200)));
    await tester.pumpWidget(
      _harness(
        MemberProfileBody(profile: profile, compact: false, onDone: () {}),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Timed out'), findsOneWidget);

    await _pastDeadline(tester);

    expect(find.textContaining('Timed out'), findsNothing);
  });

  testWidgets('timeout chips return when the deadline passes', (tester) async {
    final profile = _profile(_deadlineIn(const Duration(milliseconds: 1200)));
    await tester.pumpWidget(
      _harness(
        MemberProfileBody(
          profile: profile,
          compact: false,
          initiallyModerating: true,
          onDone: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('TIME OUT'), findsNothing);

    await _pastDeadline(tester);

    expect(find.text('TIME OUT'), findsOneWidget);
  });
}
