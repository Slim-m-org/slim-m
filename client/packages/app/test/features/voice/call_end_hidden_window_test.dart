// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that ends with the window in the tray is cleaned up at once, when
/// Flutter draws no frames and a derived provider never refreshes.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_api.dart';
import '../../support/fake_voice.dart';
import '../../support/window_lifecycle.dart';
import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _inCall = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  participants: [_ada],
);

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeSession session;

  Future<(ProviderContainer, FakeVoiceController)> hiddenInCall(
    WidgetTester tester, {
    Future<void> Function(ProviderContainer container)? before,
  }) async {
    session = FakeSession();
    final container = ProviderContainer(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(ref, session: session, initial: _inCall),
        ),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        mockApiOverride((request) async => http.Response.bytes(_pixel, 200)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await before?.call(container);
    await tester.pump(Duration.zero);
    await hideTestWindow(tester);
    return (
      container,
      container.read(voiceControllerProvider.notifier) as FakeVoiceController,
    );
  }

  testWidgets('the shares the viewer stopped are forgotten', (tester) async {
    final (container, call) = await hiddenInCall(
      tester,
      before: (container) async {
        container.listen(shareWatchProvider, (_, _) {});
        container.read(shareWatchProvider.notifier).stop('u-ada');
      },
    );
    expect(session.videoBlocked.last, isNotEmpty);

    call.set(const VoiceState());
    await tester.idle();

    // Read from the session: reading the provider would refresh it and hide a late clean-up.
    expect(session.videoBlocked.last, isEmpty);
  });

  testWidgets('a dismissed mini-player is offered again', (tester) async {
    final dismissed = <bool>[];
    final (_, call) = await hiddenInCall(
      tester,
      before: (container) async {
        container.listen(
          miniPlayerDismissedProvider,
          (_, now) => dismissed.add(now),
        );
        container.read(miniPlayerDismissedProvider.notifier).state = true;
      },
    );

    call.set(const VoiceState());
    await tester.idle();

    expect(dismissed, [true, false]);
  });

  testWidgets('the stamp pictures of the call are dropped', (tester) async {
    const picture = PictureStamp('a');
    final (container, call) = await hiddenInCall(
      tester,
      before: (container) async {
        container.listen(stampImageCacheProvider, (_, _) {});
        await tester.runAsync(
          () => container.read(stampImageCacheProvider).load(picture),
        );
      },
    );
    final cache = container.read(stampImageCacheProvider);
    expect(cache.holds(picture), isTrue);

    call.set(const VoiceState());
    await tester.idle();

    expect(cache.holds(picture), isFalse);
  });
}
