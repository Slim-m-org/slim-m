// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Members tab's add list: everyone who could be given the role, shown
/// before any search, most recently active first, with a short activity label.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/providers/role_candidates.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_members_tab.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/reduced_motion_harness.dart';
import 'roles_config_harness.dart';

const _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

api.UserProfile _member(String id, {bool holds = false, bool bot = false}) =>
    api.UserProfile(
      id: id,
      username: id,
      displayName: id,
      createdAt: 0,
      isBot: bot,
      roleIds: holds ? const ['role-mod'] : const [],
    );

final _now = DateTime.now().millisecondsSinceEpoch;

Future<ConfigHarness> _open(
  WidgetTester tester,
  List<api.UserProfile> members, {
  Map<String, int> activity = const {},
}) async {
  final h = ConfigHarness(
    handler: (request) => request.url.path == '/members/activity'
        ? jsonOk([
            for (final e in activity.entries)
              {'user_id': e.key, 'last_posted_at': e.value},
          ])
        : null,
  );
  await h.pump(
    tester,
    const RoleMembersTab(role: _role),
    overrides: [membersProvider.overrideWith((ref) async => members)],
  );
  await pumpFrames(tester);
  return h;
}

/// The tab's list, not the search field's own scrollable above it.
Finder get _list => find.byWidgetPredicate((w) => w is Scrollable).last;

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('with no search, people to add are listed, newest poster first', (
    tester,
  ) async {
    await _open(
      tester,
      [
        _member('quiet'),
        _member('chatty'),
        _member('lurker'),
        _member('holder', holds: true),
      ],
      activity: {
        'chatty': _now - const Duration(hours: 2).inMilliseconds,
        'quiet': _now - const Duration(days: 9).inMilliseconds,
      },
    );

    expect(find.text('Add to this role'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Add'), findsNWidgets(3));
    expect(_top(tester, 'chatty'), lessThan(_top(tester, 'quiet')));
    expect(_top(tester, 'quiet'), lessThan(_top(tester, 'lurker')));
    expect(find.text('Posted 2h ago'), findsOneWidget);
    expect(find.text('Posted 1w ago'), findsOneWidget);
    expect(find.text('No posts yet'), findsOneWidget);
    expect(find.text('Add someone from the list above.'), findsNothing);
  });

  testWidgets('bots wait for a search, as the add picker always did', (
    tester,
  ) async {
    await _open(tester, [_member('person'), _member('helper_bot', bot: true)]);

    expect(find.text('person'), findsOneWidget);
    expect(find.text('helper_bot'), findsNothing);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'helper',
    );
    await pumpFrames(tester);

    expect(find.text('helper_bot'), findsOneWidget);
    expect(find.text('person'), findsNothing);
  });

  testWidgets('a small Space lists everyone, with no Show more', (
    tester,
  ) async {
    await _open(tester, [for (var i = 0; i < 20; i++) _member('p$i')]);

    expect(find.widgetWithText(AppButton, 'Add'), findsNWidgets(20));
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets('a long list shows twenty, then more on request', (tester) async {
    await _open(tester, [for (var i = 0; i < 30; i++) _member('p$i')]);

    expect(find.widgetWithText(AppButton, 'Add'), findsNWidgets(20));
    expect(find.text('p9'), findsNothing);
    await tester.ensureVisible(find.text('Show 10 more'));
    await tester.pump();
    await tester.tap(find.text('Show 10 more'));
    await pumpFrames(tester);

    expect(find.textContaining('Show'), findsNothing);
    await tester.scrollUntilVisible(find.text('p9'), 200, scrollable: _list);
    expect(
      find.text('p9'),
      findsOneWidget,
      reason: 'last by name, so last shown',
    );
  });

  testWidgets('an unasked row adds only from its Add button', (tester) async {
    final h = await _open(tester, [_member('nadia')]);

    await tester.tap(find.text('nadia'));
    await pumpFrames(tester);
    expect(h.writes, isEmpty, reason: 'a stray tap on the row grants nothing');

    await tester.tap(find.widgetWithText(AppButton, 'Add'));
    await pumpFrames(tester);
    expect(h.writes.map((w) => '${w.method} ${w.path}'), [
      'PUT /members/nadia/roles/role-mod',
    ]);
  });

  testWidgets('a searched row still adds on tap', (tester) async {
    final h = await _open(tester, [_member('nadia'), _member('omar')]);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'nad',
    );
    await pumpFrames(tester);
    await tester.tap(find.text('nadia'));
    await pumpFrames(tester);

    expect(h.writes.map((w) => '${w.method} ${w.path}'), [
      'PUT /members/nadia/roles/role-mod',
    ]);
  });

  testWidgets('the list waits for activity before it shows any row', (
    tester,
  ) async {
    final activity = Completer<Map<String, int>>();
    // Reduced motion stills the spinner, which would otherwise never let the harness settle.
    await ConfigHarness().pump(
      tester,
      MediaQuery(
        data: reducedMotionData().copyWith(size: const Size(900, 900)),
        child: const RoleMembersTab(role: _role),
      ),
      overrides: [
        membersProvider.overrideWith(
          (ref) async => [_member('alpha'), _member('zed')],
        ),
        memberActivityProvider.overrideWith((ref) => activity.future),
      ],
    );
    await pumpFrames(tester);

    expect(find.text('Add to this role'), findsOneWidget);
    expect(find.text('alpha'), findsNothing, reason: 'no row before its order');
    expect(find.widgetWithText(AppButton, 'Add'), findsNothing);

    activity.complete({'zed': _now});
    await pumpFrames(tester);

    expect(_top(tester, 'zed'), lessThan(_top(tester, 'alpha')));
    expect(find.text('Posted just now'), findsOneWidget);
  });

  testWidgets('Enter in an empty search adds nobody', (tester) async {
    final h = await _open(tester, [_member('nadia')]);

    await tester.tap(find.byWidgetPredicate((w) => w is TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);

    expect(h.writes, isEmpty);
    expect(find.text('Enter'), findsNothing);
  });

  testWidgets('without activity from the server, no one reads as silent', (
    tester,
  ) async {
    final h = ConfigHarness(
      handler: (request) => request.url.path == '/members/activity'
          ? http.Response('{"error":"not found"}', 404)
          : null,
    );
    await h.pump(
      tester,
      const RoleMembersTab(role: _role),
      overrides: [
        membersProvider.overrideWith((ref) async => [_member('nadia')]),
      ],
    );
    await pumpFrames(tester);

    expect(find.text('@nadia'), findsOneWidget);
    expect(find.text('No posts yet'), findsNothing);
  });

  testWidgets('a search that matches nobody says so', (tester) async {
    await _open(tester, [_member('nadia')]);

    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'zzz',
    );
    await pumpFrames(tester);

    expect(find.text('No one matches'), findsOneWidget);
  });
}
