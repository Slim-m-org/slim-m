// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM row whose other people have left the Space reads as such.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_app/src/features/channels/widgets/group_avatar_stack.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'group_dm_harness.dart';

class _Server extends GroupDmServer {
  _Server({required this.profileExists});

  final bool profileExists;

  @override
  Future<http.Response> handle(http.Request request) {
    if (request.url.path == '/users') {
      return Future.value(
        jsonResponse([if (profileExists) personJson('u99', 'Gone')]),
      );
    }
    return super.handle(request);
  }
}

Channel _pair(String peer) => Channel(
  id: 'p1',
  name: 'Gone',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: peer,
);

Future<void> _pump(WidgetTester tester, GroupDmServer server, Channel c) async {
  final container = groupDmContainer(server);
  addTearDown(container.dispose);
  await pumpGroupDm(tester, container, DmRow(channel: c, selected: false));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Finder _ofType<T extends Widget>() => find.byWidgetPredicate((w) => w is T);

const _rowDimension = AppAvatarSize.s28;

/// Where the badge glyph must land: the dot's centre on the 28px avatar.
Offset _slotCentre(WidgetTester tester, Finder avatar) =>
    tester.getTopLeft(avatar) +
    const AppAvatarGeometry(_rowDimension, badge: true).dotCenter;

Finder _glyph(AppAvatarBadge badge) => find.byIcon(badge.icon);

void _expectBadgeInDotSlot(
  WidgetTester tester,
  AppAvatarBadge badge,
  Finder avatar,
) {
  expect(_glyph(badge), findsOneWidget);
  final glyph = tester.getRect(_glyph(badge));
  expect((glyph.center - _slotCentre(tester, avatar)).distance, lessThan(0.5));
  expect(
    glyph.width,
    closeTo(
      const AppAvatarGeometry(_rowDimension, badge: true).markDiameter,
      0.01,
    ),
  );
  expect(_ofType<AppStatusDot>(), findsNothing);
}

void main() {
  testWidgets('a peer missing from the roster shows the left badge, no text', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _pair('u99'));
    expect(find.text('Left the Space'), findsNothing);
    expect(find.text('Gone'), findsOneWidget);
    _expectBadgeInDotSlot(tester, AppAvatarBadge.left, _ofType<AppAvatar>());
    expect(_glyph(AppAvatarBadge.deleted), findsNothing);
  });

  testWidgets('a peer whose account is gone shows the deleted badge', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: false), _pair('u99'));
    expect(find.text('Deleted user'), findsNothing);
    _expectBadgeInDotSlot(tester, AppAvatarBadge.deleted, _ofType<AppAvatar>());
    expect(_glyph(AppAvatarBadge.left), findsNothing);
  });

  testWidgets('a peer still in the roster looks ordinary', (tester) async {
    await _pump(tester, _Server(profileExists: true), _pair('u1'));
    expect(find.text('Left the Space'), findsNothing);
    expect(find.text('Deleted user'), findsNothing);
    expect(_glyph(AppAvatarBadge.left), findsNothing);
    expect(_glyph(AppAvatarBadge.deleted), findsNothing);
  });

  testWidgets('a group is marked only when everyone else has left', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _group('self,u1,u99'));
    expect(find.text('Left the Space'), findsNothing);
    expect(_glyph(AppAvatarBadge.left), findsNothing);
  });

  testWidgets('a group everyone else has left badges the stack slot', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _group('self,u98,u99'));
    expect(find.text('Left the Space'), findsNothing);
    _expectBadgeInDotSlot(
      tester,
      AppAvatarBadge.left,
      _ofType<GroupAvatarStack>(),
    );
  });

  testWidgets('the row still announces the state to a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _Server(profileExists: true), _pair('u99'));
    expect(
      tester.getSemantics(_ofType<AppListRow>()).label,
      'Gone, left the space',
    );
    handle.dispose();
  });

  testWidgets('hovering a departed row names the badge in words', (
    tester,
  ) async {
    await _pump(tester, _Server(profileExists: true), _pair('u99'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_ofType<AppListRow>()));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Left the Space'), findsOneWidget);
    expect(_ofType<Tooltip>(), findsOneWidget);
  });

  testWidgets('hovering a deleted row says deleted user', (tester) async {
    await _pump(tester, _Server(profileExists: false), _pair('u99'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_ofType<AppListRow>()));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Deleted user'), findsOneWidget);
  });
}

Channel _group(String members) => Channel(
  id: 'g9',
  name: 'Group',
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmMemberIds: members,
);
