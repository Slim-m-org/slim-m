// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Jellyfin sign-in sheet names the server that will receive the password,
/// warns when that address is not encrypted, and refuses a server swapped
/// underneath it. See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/direct_play_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/direct_play_sign_in_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';
import 'direct_play_fakes.dart';

const _unencrypted = 'This address is not encrypted. Check it is yours.';

api.WatchDirectPlay _offer(String baseUrl) =>
    api.WatchDirectPlay(baseUrl: baseUrl, verifiedUserIds: const ['me']);

Future<({Rig rig, DirectPlayController controller})> _open(
  WidgetTester tester,
  String baseUrl, {
  double width = 1280,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rig = Rig(credential: false);
  final controller = DirectPlayController(rig.env(), 'call-1');
  addTearDown(controller.dispose);
  await controller.onRoom(room(rig, offer: _offer(baseUrl)));
  await controller.enable();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(
        brightness,
        brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
      ),
      builder: (context, child) =>
          RepaintBoundary(key: snapshotBoundary, child: child),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                unawaited(showDirectPlaySignIn(context, controller)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (rig: rig, controller: controller);
}

Finder _field(String hint) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == hint,
);

void main() {
  setUpAll(loadRealFonts);

  for (final width in const [390.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      final label = '${width.toInt()}-${brightness.name}';
      testWidgets('a plain http server is named and warned about ($label)', (
        tester,
      ) async {
        await _open(tester, jellyUrl, width: width, brightness: brightness);
        expect(find.text('Signing in to 10.0.0.5:8096'), findsOneWidget);
        expect(find.text(_unencrypted), findsOneWidget);
        await writeSnapshot(tester, 'direct-play-sign-in-$label');
      });
    }
  }

  testWidgets('an https server shows its host and no warning', (tester) async {
    await _open(tester, 'https://jelly.example.com/jellyfin');
    expect(find.text('Signing in to jelly.example.com'), findsOneWidget);
    expect(find.text(_unencrypted), findsNothing);
  });

  testWidgets('a server swapped while the sheet is open gets no password', (
    tester,
  ) async {
    final open = await _open(tester, 'https://jelly.example.com');
    await open.controller.onRoom(
      room(open.rig, offer: _offer('https://lookalike.example.net')),
    );
    await tester.enterText(_field('Jellyfin name'), 'nick');
    await tester.enterText(_field('Password'), 'right');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(
      find.text('The server changed. Close this and try again.'),
      findsOneWidget,
    );
    expect(
      open.rig.mediaCalls.where((c) => c.endsWith('/Users/AuthenticateByName')),
      isEmpty,
    );
  });

  testWidgets('the server shown is the one that receives the password', (
    tester,
  ) async {
    final open = await _open(tester, 'https://jelly.example.com');
    await tester.enterText(_field('Jellyfin name'), 'nick');
    await tester.enterText(_field('Password'), 'right');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      open.rig.mediaCalls.where((c) => c.endsWith('/Users/AuthenticateByName')),
      hasLength(1),
    );
    open.controller.dispose();
  });
}
