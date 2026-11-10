// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text channel's resting transcript and the states around it, wide and on a
/// phone: scrolled away, unread, typing, paging, read-only, timed out and a
/// hidden member list.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart'
    show memberPaneVisibleProvider;
import 'package:slimm_app/src/features/messages/providers/typing_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart'
    show appFocusedProvider;

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController, connectedCallState;
import '../ui_snapshot_support.dart';
import 'ui_review_conversation_and_search_data.dart';
import 'ui_review_conversation_and_search_router.dart';
import 'ui_review_conversation_and_search_support.dart';

class _FixedTyping extends StateNotifier<Set<String>>
    implements TypingController {
  _FixedTyping(super.ids);

  @override
  void notifyTyping() {}
}

class _FixedHistory extends ChannelHistoryController {
  _FixedHistory(Ref ref, ChannelHistory fixed) : super(ref, 'c-general') {
    state = fixed;
  }
}

/// The transcript's tail already shown, then pulled into history and back a little.
Future<void> _scrollAwayThenBack(ReviewRig rig) async {
  final middle = Offset(
    rig.viewport.size.width / 2,
    rig.viewport.size.height / 2,
  );
  await rig.tester.dragFrom(middle, const Offset(0, 900));
  await rig.pumpFor();
  await rig.tester.dragFrom(middle, const Offset(0, -120));
  await rig.settle();
}

/// The shared call fixture's fixed start reads as weeks in the call bar's timer.
VoiceState _callStartedAMinuteAgo() => connectedCallState.copyWith(
  connectedAt: DateTime.now().subtract(
    const Duration(minutes: 12, seconds: 34),
  ),
);

int _timeoutEnd() => DateTime.now()
    .add(const Duration(days: 2, hours: 3))
    .millisecondsSinceEpoch;

void main() {
  setUpAll(loadRealFonts);

  const wide = [ReviewViewport.desktop];
  const phone = [ReviewViewport.phone];

  reviewCase(
    'channel-text-wide',
    state: 'jump-to-latest',
    viewports: wide,
    messages: fullTranscript,
    act: _scrollAwayThenBack,
  );
  reviewCase(
    'channel-text-wide',
    state: 'new-divider',
    viewports: wide,
    messages: fullTranscript,
    overrides: () => [appFocusedProvider.overrideWithValue(false)],
    seed: (store) => store.setReadMarker('c-general', 30),
  );
  reviewCase(
    'channel-text-wide',
    state: 'typing',
    viewports: wide,
    messages: fullTranscript,
    overrides: () => [
      typingControllerProvider.overrideWith(
        (ref, id) => _FixedTyping({'user-ada', 'user-long-name'}),
      ),
    ],
  );
  reviewCase(
    'channel-text-wide',
    state: 'loading-earlier',
    viewports: wide,
    overrides: () => [
      reducedMotion(),
      channelHistoryProvider.overrideWith(
        (ref, id) => _FixedHistory(ref, const ChannelHistory(loading: true)),
      ),
    ],
  );
  reviewCase(
    'channel-text-wide',
    state: 'earlier-error',
    viewports: wide,
    overrides: () => [
      channelHistoryProvider.overrideWith(
        (ref, id) => _FixedHistory(ref, const ChannelHistory(failed: true)),
      ),
    ],
  );
  reviewCase(
    'channel-text-wide',
    state: 'read-only',
    viewports: wide,
    messages: fullTranscript,
    permissions: Perm.viewChannel,
  );
  reviewCase(
    'channel-text-wide',
    state: 'timed-out',
    viewports: wide,
    messages: fullTranscript,
    timedOutUntil: _timeoutEnd(),
    timeoutReason: 'Repeated off-topic links after two warnings.',
  );
  reviewCase(
    'channel-text-wide',
    state: 'header-pills',
    viewports: wide,
    messages: fullTranscript,
    serve: (request) async => switch (request.url.path) {
      '/channels/c-general/pins' => jsonOk(pinsJson()),
      '/channels/c-general/threads' => jsonOk(threadsJson()),
      _ => null,
    },
  );
  reviewCase(
    'channel-text-wide',
    state: 'members-hidden',
    viewports: wide,
    messages: fullTranscript,
    overrides: () => [memberPaneVisibleProvider.overrideWith((ref) => false)],
  );

  reviewCase(
    'channel-text-phone',
    state: 'read-only',
    viewports: phone,
    messages: fullTranscript,
    permissions: Perm.viewChannel,
  );
  reviewCase(
    'channel-text-phone',
    state: 'timed-out',
    viewports: phone,
    messages: fullTranscript,
    timedOutUntil: _timeoutEnd(),
    timeoutReason: 'Repeated off-topic links after two warnings.',
  );
  reviewCase(
    'channel-text-phone',
    state: 'typing',
    viewports: phone,
    messages: fullTranscript,
    overrides: () => [
      typingControllerProvider.overrideWith(
        (ref, id) => _FixedTyping({'user-ada'}),
      ),
    ],
  );
  reviewCase(
    'channel-text-phone',
    state: 'voice-chat',
    viewports: phone,
    router: () => reviewRouter('/channels/c-main?chat=1'),
    // The chat pages its history in once on arrival, which changes what it says at the top.
    act: (rig) => rig.settle(),
    messages: () => [...fixtureMessages, ...voiceChat()],
    overrides: () => [
      voiceControllerProvider.overrideWith(
        (ref) => SnapshotVoiceController(ref, _callStartedAMinuteAgo()),
      ),
    ],
  );
}
