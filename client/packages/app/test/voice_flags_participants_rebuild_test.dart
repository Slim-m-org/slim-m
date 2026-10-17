// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pins the rebuild boundary `voice_flags.dart` exists to draw:
/// `voiceFlagsProvider` and `voiceParticipantsProvider` are two separate
/// `select` forwards over the same `voiceControllerProvider`, so a widget
/// watching only one must never rebuild when only the other's slice changes.
///
/// Counts real builds with a plain counter rather than asserting on a
/// rendered value, since the point under test is whether `build` ran at all,
/// not what it would have rendered if it had.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

/// A [VoiceController] a test can push `participants` or flag changes into
/// after mount, unlike `voice_controller_harness.dart`'s own
/// `FixedVoiceController`, which only ever pins one state at construction.
class _MutableVoiceController extends VoiceController {
  _MutableVoiceController(super.ref) : super(session: FakeSession());

  void setMicrophoneEnabled(bool enabled) =>
      state = state.copyWith(microphoneEnabled: enabled);

  void setParticipants(List<VoiceParticipant> participants) =>
      state = state.copyWith(participants: participants);
}

VoiceParticipant _participant(String identity) => VoiceParticipant(
  identity: identity,
  name: identity,
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

int _flagsBuilds = 0;
int _participantsBuilds = 0;

/// Watches only the flags slice - what `railVoiceToggleButtons` and the
/// other mic/camera/deafen surfaces actually need.
class _FlagsOnlyConsumer extends ConsumerWidget {
  const _FlagsOnlyConsumer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(voiceFlagsProvider);
    _flagsBuilds++;
    return const SizedBox.shrink();
  }
}

/// Watches only the roster slice - what a participant grid or filmstrip
/// actually needs.
class _ParticipantsOnlyConsumer extends ConsumerWidget {
  const _ParticipantsOnlyConsumer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(voiceParticipantsProvider);
    _participantsBuilds++;
    return const SizedBox.shrink();
  }
}

void main() {
  testWidgets(
    'a flags-only watcher never rebuilds on a participants-only change, and '
    'a participants-only watcher never rebuilds on a flags-only change',
    (tester) async {
      _flagsBuilds = 0;
      _participantsBuilds = 0;

      final container = ProviderContainer(
        overrides: [
          voiceControllerProvider.overrideWith(_MutableVoiceController.new),
        ],
      );
      addTearDown(container.dispose);
      final controller =
          container.read(voiceControllerProvider.notifier)
              as _MutableVoiceController;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Column(
              children: [_FlagsOnlyConsumer(), _ParticipantsOnlyConsumer()],
            ),
          ),
        ),
      );

      final flagsAfterMount = _flagsBuilds;
      final participantsAfterMount = _participantsBuilds;
      expect(flagsAfterMount, greaterThan(0));
      expect(participantsAfterMount, greaterThan(0));

      // Only the roster changes now.
      controller.setParticipants([_participant('remote-1')]);
      await tester.pump();

      expect(
        _participantsBuilds,
        greaterThan(participantsAfterMount),
        reason: 'the participants watcher must react to its own slice',
      );
      expect(
        _flagsBuilds,
        flagsAfterMount,
        reason: 'a roster-only change must never rebuild the flags watcher',
      );

      final flagsAfterRoster = _flagsBuilds;
      final participantsAfterRoster = _participantsBuilds;

      // Only a flag changes now.
      controller.setMicrophoneEnabled(false);
      await tester.pump();

      expect(
        _flagsBuilds,
        greaterThan(flagsAfterRoster),
        reason: 'the flags watcher must react to its own slice',
      );
      expect(
        _participantsBuilds,
        participantsAfterRoster,
        reason:
            'a flag-only change must never rebuild the participants watcher',
      );
    },
  );
}
