// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call fixtures the voice review suites build on: people, a call that
/// has run a while, a pinned controller, and a session with stand-in video.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/voice/voice_controller_harness.dart' show FakeSession;
import '../support/fake_voice.dart';

/// A call that has been running for a believable while, so the header clock
/// reads minutes rather than the months since a fixed fixture date.
DateTime callStartedAgo([
  Duration ago = const Duration(minutes: 14, seconds: 32),
]) => DateTime.now().subtract(ago);

/// Pins [VoiceState] and answers with [session], which a capture can subclass
/// to give the call devices or a video health map.
class ReviewVoiceController extends FakeVoiceController {
  ReviewVoiceController(super.ref, VoiceState fixed, {FakeSession? session})
    : super(initial: fixed, session: session ?? ReviewVoiceSession());
}

/// Flat coloured stand-ins for a live camera and a shared screen.
class ReviewVoiceSession extends FakeSession {
  ReviewVoiceSession({
    super.needsSource,
    super.cameraNeedsSelection,
    super.cameraDeviceList,
    super.canFlipCamera,
    super.audioInputDeviceList,
    super.audioOutputDeviceList,
    super.sources,
  }) : super(supportsAudioInputSelection: false);

  final _frames = <String, FirstFrameTracker>{};

  @override
  bool hasScreenAudio(String identity) => true;

  // The tile holds its avatar over a camera until a frame is reported, so the stand-in reports one.
  @override
  Widget cameraViewFor(String identity) => CameraFrameReporter(
    tracker: _frames.putIfAbsent(
      identity,
      () => FirstFrameTracker()..markFirstFrame(),
    ),
    child: ColoredBox(
      color: _cameraColors[identity.hashCode.abs() % _cameraColors.length],
      child: const SizedBox.expand(),
    ),
  );

  @override
  Widget screenShareViewFor(String identity) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1F3A5F), Color(0xFF3C6E71), Color(0xFFE0B04A)],
      ),
    ),
    child: SizedBox.expand(),
  );
}

const _cameraColors = [
  Color(0xFF2D5F7C),
  Color(0xFF5B4B8A),
  Color(0xFF3F6B4A),
  Color(0xFF8A5A44),
];

Override reviewVoice(VoiceState state, {FakeSession? session}) =>
    voiceControllerProvider.overrideWith(
      (ref) => ReviewVoiceController(ref, state, session: session),
    );

VoiceParticipant reviewPerson(
  String id,
  String name, {
  bool local = false,
  bool speaking = false,
  bool muted = false,
  bool camera = false,
  bool sharing = false,
}) => VoiceParticipant(
  identity: id,
  name: name,
  isLocal: local,
  isSpeaking: speaking,
  isMuted: muted,
  isCameraOn: camera,
  isScreenSharing: sharing,
);

/// A DM ring controller pinned to [pinned], so an overlay renders one state.
class PinnedRing extends DmCallRingController {
  PinnedRing(super.ref, DmCallRingState pinned) {
    state = pinned;
  }
}
