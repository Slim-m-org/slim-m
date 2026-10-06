// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The role pane's tab strip and the members tab's "+N more" expander are
/// real controls: Tab reaches them, Enter and Space open them, and a screen
/// reader hears a button, with the active tab reported as selected.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/role_detail.dart';
import 'package:slimm_app/src/screens/admin/role_display_tab.dart';
import 'package:slimm_app/src/screens/admin/role_members_tab.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

Widget _app(Widget body, {List<api.UserProfile> members = const []}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      membersProvider.overrideWith((ref) async => members),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: body),
    ),
  );
}

/// True when the focused node is the nearest Focus around [finder]'s match.
bool _focusWraps(Finder finder) {
  final node = FocusManager.instance.primaryFocus;
  final focus = node?.context;
  if (focus == null || node is FocusScopeNode) return false;
  Element? nearest;
  finder.evaluate().single.visitAncestorElements((element) {
    if (element.widget is Focus) nearest = element;
    return nearest == null;
  });
  return identical(nearest, focus);
}

Future<void> _tabUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40 && !_focusWraps(finder); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_focusWraps(finder), isTrue, reason: 'Tab never reached $finder');
}

SemanticsNode _control(WidgetTester tester, Finder label) =>
    tester.getSemantics(
      find.ancestor(of: label, matching: find.byType(FocusableTapTarget)),
    );

Tristate _selected(WidgetTester tester, Finder label) =>
    _control(tester, label).flagsCollection.isSelected;

void main() {
  testWidgets('a role tab is a button and the active one reports selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const RoleDetail(role: _role)));
    await tester.pumpAndSettle();

    for (final label in ['Permissions', 'Display']) {
      expect(
        _control(tester, find.text(label)).flagsCollection.isButton,
        isTrue,
        reason: '$label should be exposed as a button',
      );
    }
    expect(_selected(tester, find.text('Permissions')), Tristate.isTrue);
    expect(_selected(tester, find.text('Display')), Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('Tab reaches the Display tab and Space opens it', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const RoleDetail(role: _role)));
    await tester.pumpAndSettle();

    await _tabUntil(tester, find.text('Display'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(find.byType(RoleDisplayTab), findsOneWidget);
    expect(_selected(tester, find.text('Display')), Tristate.isTrue);
    expect(_selected(tester, find.text('Permissions')), Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('the "+N more" expander is a Tab stop and Enter expands it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const RoleMembersTab(role: _role),
        members: [
          for (var i = 0; i < 8; i++)
            api.UserProfile(
              id: 'p$i',
              username: 'person$i',
              displayName: 'person$i',
              createdAt: 0,
              roleIds: const ['role-mod'],
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final more = find.textContaining('+ 3 more');
    expect(more, findsOneWidget);
    expect(_control(tester, more).flagsCollection.isButton, isTrue);

    await _tabUntil(tester, more);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.textContaining('+ 3 more'), findsNothing);
    expect(find.text('person7'), findsOneWidget);
    handle.dispose();
  });
}
