// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A lounge tile takes its member's profile colour, and the paused-preview
/// card reads centred without its old icon.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_tile_backdrop.dart';
import 'package:slimm_app/src/features/voice/widgets/video_state_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Widget _app(Widget child, {api.UserProfile? profile}) => ProviderScope(
  overrides: [
    userProfileProvider('u-ada').overrideWith((ref) async => profile),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: Center(child: child)),
  ),
);

Color _backdrop(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(CallTileBackdrop),
            matching: find.byType(ColoredBox),
          )
          .first,
    )
    .color;

void main() {
  testWidgets('the tile is filled with the member\'s custom colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const CallParticipantTile(participant: _ada),
        profile: const api.UserProfile(
          id: 'u-ada',
          username: 'ada',
          displayName: 'Ada',
          createdAt: 0,
          profileColor: 1,
          profileColorRgb: 0x336699,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_backdrop(tester), const Color(0xFF336699));
  });

  testWidgets('without a resolved profile the tile keeps the raised surface', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const CallParticipantTile(participant: _ada)));
    await tester.pumpAndSettle();
    expect(_backdrop(tester), AppTokens.dark.surfaceRaised);
  });

  testWidgets('a card with no icon keeps its title centred', (tester) async {
    await tester.pumpWidget(
      _app(
        const SizedBox(
          width: 400,
          height: 200,
          child: VideoStateCard(
            title: "Preview paused while you're in another window",
            identity: 'u-ada',
            name: 'Ada',
            actionLabel: 'Resume',
            onAction: _noop,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(VideoStateCard));
    final title = tester.getRect(find.textContaining('Preview paused'));
    expect((title.center.dx - card.center.dx).abs(), lessThan(1));
    expect(find.byType(Icon), findsNothing);
  });
}

void _noop() {}
