// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's game on their profile card: title, Steam header art with a game
/// icon fallback, elapsed time, and a Play button that opens
/// `steam://run/<id>` (decision 0115).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_activity.dart';
import 'package:slimm_app/src/features/members/widgets/activity_card.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_activity.dart';
import 'package:slimm_app/src/features/settings/providers/linked_accounts.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../support/async_wait.dart';

const _startedAt = 1788000000000;
const _art =
    'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/730/header.jpg';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

api.PresenceActivity _game({String? artUrl, int? appId = 730}) =>
    api.PresenceActivity(
      kind: api.ActivityKind.playing,
      title: 'Counter-Strike 2',
      source: 'steam',
      startedAt: _startedAt,
      artUrl: artUrl,
      steamAppId: appId,
    );

Future<List<Uri>> _pump(
  WidgetTester tester,
  api.PresenceActivity activity,
) async {
  final launched = <Uri>[];
  final container = ProviderContainer(
    overrides: [
      externalUrlLauncherProvider.overrideWithValue((
        url, {
        mode = LaunchMode.platformDefault,
      }) async {
        launched.add(url);
        return true;
      }),
      activityClockProvider.overrideWithValue(
        () => DateTime.fromMillisecondsSinceEpoch(
          _startedAt + const Duration(minutes: 12).inMilliseconds,
        ),
      ),
      activityArtImageProvider.overrideWithValue((_) => MemoryImage(_pixel)),
    ],
  );
  addTearDown(container.dispose);
  container.read(presenceActivityProvider.notifier).apply('u1', activity);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: MemberProfileActivity(userId: 'u1')),
      ),
    ),
  );
  await pumpFrames(tester);
  return launched;
}

void main() {
  testWidgets('a Steam game shows its title, source and time played', (
    tester,
  ) async {
    await _pump(tester, _game(artUrl: _art));

    expect(find.text('Counter-Strike 2'), findsOneWidget);
    expect(find.text('PLAYING ON STEAM'), findsOneWidget);
    expect(find.text('Playing for 12 min'), findsOneWidget);
    expect(find.byIcon(AppIcons.playing), findsNothing, reason: 'art drawn');
  });

  testWidgets('Play opens steam://run with the app id', (tester) async {
    final launched = await _pump(tester, _game(artUrl: _art));

    await tester.tap(find.widgetWithText(AppButton, 'Play'));
    await pumpFrames(tester);

    expect(launched.single.toString(), 'steam://run/730');
  });

  testWidgets('a game with no Steam id has no Play button', (tester) async {
    await _pump(tester, _game(appId: null));

    expect(find.text('Counter-Strike 2'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Play'), findsNothing);
  });

  testWidgets('no art falls back to the game icon', (tester) async {
    await _pump(tester, _game());

    expect(find.byIcon(AppIcons.playing), findsOneWidget);
  });

  testWidgets('art off a Steam host is never drawn', (tester) async {
    await _pump(tester, _game(artUrl: 'https://evil.example/a.jpg'));

    expect(find.byIcon(AppIcons.playing), findsOneWidget);
  });
}
