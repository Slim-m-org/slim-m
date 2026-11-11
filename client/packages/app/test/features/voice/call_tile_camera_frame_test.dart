// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile whose camera is on keeps the avatar up until a frame has decoded,
/// so a published camera that is not flowing yet never reads as a blank tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _feed = Key('feed');
final _avatar = find.byWidgetPredicate((w) => w is UserAvatar);

Widget _tile(FirstFrameTracker? tracker) => ProviderScope(
  overrides: [userProfileProvider('u-ada').overrideWith((ref) async => null)],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Center(
        child: CallParticipantTile(
          participant: _ada,
          cameraView: CameraFrameReporter(
            tracker: tracker,
            child: const SizedBox.expand(key: _feed),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the avatar stays up until the camera has a frame', (
    tester,
  ) async {
    final tracker = FirstFrameTracker();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(_tile(tracker));
    await tester.pump();

    expect(find.byKey(_feed), findsOneWidget);
    expect(_avatar, findsOneWidget);
    expect(find.byKey(cameraStartingKey), findsOneWidget);

    tracker.markFirstFrame();
    await tester.pump();

    expect(find.byKey(_feed), findsOneWidget);
    expect(_avatar, findsNothing);
    expect(find.byKey(cameraStartingKey), findsNothing);
  });

  testWidgets('a camera with no track yet keeps the avatar', (tester) async {
    await tester.pumpWidget(_tile(null));
    await tester.pump();

    expect(_avatar, findsOneWidget);
  });

  testWidgets('the camera is not remounted when its first frame lands', (
    tester,
  ) async {
    final tracker = FirstFrameTracker();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(_tile(tracker));
    await tester.pump();
    final before = tester.element(find.byKey(_feed));

    tracker.markFirstFrame();
    await tester.pump();

    expect(tester.element(find.byKey(_feed)), same(before));
  });
}
