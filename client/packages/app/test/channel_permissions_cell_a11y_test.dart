// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid is operable without a pointer: Tab reaches each cell
/// and each column's remove control, Space and Enter activate them, and a
/// screen reader hears which permission and which column a cell belongs to.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid_rows.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_header.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

final _channel = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

const _nadia = api.UserProfile(
  id: 'm-nadia',
  username: 'nadia',
  displayName: 'Nadia',
  createdAt: 0,
);

Widget _grid(int myPermissions, {bool withNadia = false}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith(
        (ref) async => withNadia ? const [_nadia] : const <api.UserProfile>[],
      ),
      channelOverwritesProvider(_channel.id).overrideWith(
        (ref) async => withNadia
            ? const [
                api.ChannelOverwrite(
                  kind: api.OverwriteTarget.member,
                  id: 'm-nadia',
                  allow: 0,
                  deny: 0,
                ),
              ]
            : const <api.ChannelOverwrite>[],
      ),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => myPermissions),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
    ),
  );
}

final _everyoneSend = find.byKey(
  ValueKey('cell:role:${_everyone.id}:${Perm.sendMessages}'),
);

bool _focusIsWithin(Finder finder) {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  final target = finder.evaluate().single;
  var inside = identical(focus, target);
  focus.visitAncestorElements((element) {
    if (identical(element, target)) inside = true;
    return !inside;
  });
  return inside;
}

SemanticsNode _node(WidgetTester tester, Finder cell) => tester.getSemantics(
  find.descendant(of: cell, matching: find.byType(FocusableTapTarget)),
);

/// Focusability lives on a child node of the labelled button, so look through both.
bool _isTabStop(SemanticsNode node) {
  var found = node.getSemanticsData().hasAction(SemanticsAction.focus);
  node.visitChildren((child) {
    found = found || _isTabStop(child);
    return !found;
  });
  return found;
}

Future<void> _tabUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60 && !_focusIsWithin(finder); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_focusIsWithin(finder), isTrue, reason: 'Tab never reached $finder');
}

void main() {
  testWidgets('Tab reaches a cell and Space then Enter cycle it', (
    tester,
  ) async {
    await tester.pumpWidget(_grid(Perm.sendMessages));
    await tester.pumpAndSettle();

    await _tabUntil(tester, _everyoneSend);
    expect(tester.widget<Cell>(_everyoneSend).state, CellState.inherit);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(tester.widget<Cell>(_everyoneSend).state, CellState.allow);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<Cell>(_everyoneSend).state, CellState.deny);
  });

  testWidgets('a cell names its permission, its column and its state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_grid(Perm.sendMessages));
    await tester.pumpAndSettle();

    final node = _node(tester, _everyoneSend);
    expect(node.label, 'Send messages, everyone: Inherit from role');
    expect(node.flagsCollection.isButton, isTrue);
    expect(_isTabStop(node), isTrue);

    await tester.tap(_everyoneSend);
    await tester.pumpAndSettle();
    expect(
      _node(tester, _everyoneSend).label,
      'Send messages, everyone: Allow, changed',
    );
    handle.dispose();
  });

  testWidgets('every cell in a column carries a distinct label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_grid(Perm.sendMessages));
    await tester.pumpAndSettle();

    final labels = {
      for (final element in find.byType(Cell).evaluate())
        _node(tester, find.byWidget(element.widget)).label,
    };
    expect(labels.length, find.byType(Cell).evaluate().length);
    handle.dispose();
  });

  testWidgets('the remove control is reachable by Tab and Enter removes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_grid(Perm.sendMessages, withNadia: true));
    await tester.pumpAndSettle();

    final remove = find.bySemanticsLabel('Remove Nadia from this grid');
    final node = tester.getSemantics(remove);
    expect(node.flagsCollection.isButton, isTrue);
    expect(_isTabStop(node), isTrue);

    final nadiaSend = find.byKey(
      ValueKey('cell:member:m-nadia:${Perm.sendMessages}'),
    );
    final control = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is HeaderCell && w.column.id == 'm-nadia',
      ),
      matching: find.byType(AppIconButton),
    );
    await _tabUntil(tester, control);
    expect(nadiaSend, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(nadiaSend, findsNothing);
    handle.dispose();
  });

  testWidgets('on a phone width the remove control meets the 44dp target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_grid(Perm.sendMessages, withNadia: true));
    await tester.pumpAndSettle();

    final remove = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is HeaderCell && w.column.id == 'm-nadia',
      ),
      matching: find.byType(AppIconButton),
    );
    expect(tester.getSize(remove), const Size(44, 44));
  });
}
