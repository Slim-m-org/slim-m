// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice conversation header with a channel name too long for the room
/// it has.
///
/// The title sat in a `Row(mainAxisSize: min)` whose caller wraps it in an
/// `Expanded`. Expanded hands down a tight width, so min does nothing, and the
/// `Text` had no flex and no `overflow`, so it laid out at its intrinsic width
/// and ran past the header alongside the chat toggle and the canvas button.
/// Only reachable on a voice channel at a width that shows both panes, which
/// is why the snapshot matrix - whose voice fixture is named "general" - never
/// caught it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../home_shell_harness.dart';
import 'voice_controller_harness.dart' show FixedVoiceController;

/// Long enough to overrun the header at any width the shell offers it.
const _longName =
    'weekly-design-review-and-retrospective-with-the-whole-team-and-guests';

void main() {
  testWidgets('a long voice channel name ellipsizes instead of overflowing', (
    tester,
  ) async {
    final s = setup(
      httpClient: quietClient(),
      signedIn: true,
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              state: VoiceSessionState.connected,
              channelId: 'c1',
            ),
          ),
        ),
      ],
    );
    await MessageStore(s.db).upsertChannels([
      const api.Channel(id: 'c1', name: _longName, kind: 'voice', createdAt: 0),
    ]);

    await pumpAtWidth(tester, s.container, 1000, location: '/channels/c1');

    expect(
      tester.takeException(),
      isNull,
      reason: 'a long name must not overflow the voice header',
    );

    // Drawn in the rail as well, and neither may run off the edge.
    final titles = find.text(_longName);
    expect(titles, findsWidgets);
    for (final element in titles.evaluate()) {
      final text = element.widget as Text;
      expect(
        text.overflow,
        TextOverflow.ellipsis,
        reason: 'it has to be cut with an ellipsis, not just clipped',
      );
      expect(
        tester.getRect(find.byWidget(text)).right,
        lessThanOrEqualTo(1000.0),
        reason: 'and stay inside the viewport it was given',
      );
    }

    await teardown(tester, s.container, s.db);
  });
}
