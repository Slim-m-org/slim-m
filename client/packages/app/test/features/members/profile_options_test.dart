// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Profile pane options no other suite operates: the blur-saved pronouns and
/// about fields, the colour swatches, Copy username and the activity switches.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/activity_feeds.dart';
import 'package:slimm_app/src/features/members/providers/activity_sharing_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/spotify/spotify_config.dart';
import 'package:slimm_app/src/spotify/spotify_link.dart';
import 'package:slimm_app/src/features/members/widgets/activity_sharing_section.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_settings_section.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FakeNowPlaying implements NowPlayingSource {
  @override
  Stream<NowPlaying?> watch() => const Stream.empty();
}

class _FakeLinker implements SpotifyLinker {
  int begun = 0;

  @override
  Future<void> begin() async => begun++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGames implements GameSource {
  @override
  Stream<RunningGame?> watch() => const Stream.empty();
}

Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester,
  Widget pane, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final patches = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.url.path != '/me') return http.Response('', 404);
        if (request.method == 'PATCH') {
          patches.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'nc1107',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
            'profile_color': 3,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: pane)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return patches;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Pronouns and About each save on blur', (tester) async {
    final patches = await _pump(tester, const ProfileFieldsSection());

    await tester.tap(find.bySemanticsLabel('Pronouns').first);
    await tester.enterText(find.byType(TextField).first, ' they/them ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(patches, contains(equals({'pronouns': 'they/them'})));

    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, 'Builds things');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(patches, contains(equals({'about': 'Builds things'})));
    expect(
      patches,
      hasLength(2),
      reason: 'each field sends once, only when its text changed',
    );
  });

  testWidgets('focusing and leaving a field without typing sends nothing', (
    tester,
  ) async {
    final patches = await _pump(tester, const ProfileFieldsSection());

    await tester.tap(find.byType(TextField).first);
    await tester.tap(find.byType(TextField).last);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    expect(patches, isEmpty);
  });

  testWidgets('tapping a Profile colour swatch saves that colour', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final patches = await _pump(tester, const ProfileFieldsSection());

    await tester.tap(find.bySemanticsLabel(RegExp('^Profile colour: Green\$')));
    await tester.pumpAndSettle();

    expect(patches, contains(equals({'profile_color': 4})));
    semantics.dispose();
  });

  testWidgets('Copy username puts @username on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, const AvatarSettingsSection());

    await tester.tap(find.byTooltip('Copy username'));
    await tester.pumpAndSettle();

    expect(copied, '@nc1107');
  });

  testWidgets('every activity switch flips its own stored preference', (
    tester,
  ) async {
    final linker = _FakeLinker();
    await _pump(
      tester,
      const ActivitySharingSection(),
      overrides: [
        nowPlayingSourceProvider.overrideWithValue(_FakeNowPlaying()),
        gameSourceProvider.overrideWithValue(_FakeGames()),
        spotifyClientIdProvider.overrideWithValue('client'),
        spotifyLinkerProvider.overrideWith((ref) => linker),
      ],
    );
    final prefs = await SharedPreferences.getInstance();

    for (final entry in {
      "Show what I'm listening to": shareListeningKey,
      'Show my current game': shareGameKey,
    }.entries) {
      final toggle = find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == entry.key,
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(prefs.getBool(entry.value), isTrue, reason: entry.key);
    }

    expect(
      find.text('Show my Spotify track'),
      findsNothing,
      reason: 'Spotify lives in Connections',
    );
  });
}
