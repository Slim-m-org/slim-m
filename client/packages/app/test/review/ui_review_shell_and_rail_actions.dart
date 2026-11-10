// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gestures, seeds and fake-server answers the shell-and-rail review
/// suites share, on top of the mount in `ui_review_shell_and_rail_support.dart`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_shell_and_rail_support.dart';

/// What an ordinary member holds: see and write, react, nothing that manages.
const memberPermissions =
    Perm.viewChannel | Perm.sendMessages | Perm.addReactions;

/// A signed-in caller holding exactly [permissions], as `GET /me` would report.
Override meOverride(int permissions, {String? statusText}) =>
    meProvider.overrideWith(
      (ref) async => api.Me(
        id: 'user-nick',
        username: 'nick',
        displayName: 'Nick',
        createdAt: 0,
        permissions: permissions,
        statusText: statusText,
      ),
    );

/// [text] as the rail draws it, apart from the same words in the conversation or roster beside it.
Finder railText(String text) => find.descendant(
  of: find.byKey(ChannelRail.surfaceKey),
  matching: find.text(text),
);

/// Puts the right-click (pointer) or long-press (touch) menu of [target] on screen.
Future<void> openRowMenu(
  WidgetTester tester,
  ShellWindow window,
  Finder target,
) async {
  // Only a row under the footer scrolls into view, so the rest keep the rail at rest.
  if (tester.getCenter(target).dy > window.size.height - 120) {
    await tester.ensureVisible(target);
    await tester.pump();
  }
  if (window.isPhone) {
    await tester.longPress(target);
  } else {
    await tester.tapAt(
      tester.getCenter(target),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await settleFrames(tester);
}

/// Sets how far a channel has been read and what it holds unread, through the store's own cursor writes.
Future<void> markChannel(
  ShellScene scene,
  String id, {
  required int cursor,
  required int lastRead,
  int mentioned = 0,
  bool manuallyUnread = false,
}) async {
  final store = await scene.container.read(storeProvider.future);
  await store.advanceCursor(id, [cursor], CursorAdvance.always);
  if (mentioned > 0) await store.advanceMentionCursor(id, mentioned);
  await store.setReadMarker(id, lastRead, manuallyUnread: manuallyUnread);
}

/// Removes every channel but keeps the categories, which is what a fresh Space holds.
Future<void> emptyChannels(WidgetTester tester, ShellScene scene) async {
  final store = await scene.container.read(storeProvider.future);
  for (final channel in await store.allChannels()) {
    await store.removeChannel(channel.id);
  }
}

/// Lets a picture decode, which happens outside the test's fake clock.
Future<void> letImagesDecode(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// The fixture's server with [handler] answering first; null from it falls through to the fixture.
Override apiHandler(Future<http.Response?> Function(http.Request) handler) =>
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient(
          (request) async => await handler(request) ?? fixtureResponse(request),
        ),
      );
      ref.onDispose(client.close);
      return client;
    });

/// A JSON answer, with the status a real server would send.
http.Response jsonAnswer(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// The one text field of a sheet, found by the label it reads out.
Finder inputLabelled(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

/// Opens a sheet or dialog from the rail's own context, as the rail's menus do.
Future<void> openSheet(
  WidgetTester tester,
  Future<void> Function(BuildContext context) show,
) async {
  unawaited(show(tester.element(find.byKey(ChannelRail.surfaceKey))));
  await tester.pump();
  await tester.pump(settleDuration);
}

/// Lets an answer from the fake server land and paints what it changed.
Future<void> letRequestsLand(WidgetTester tester) async {
  await realDelay(tester);
  await tester.pump();
  await tester.pump(settleDuration);
}
