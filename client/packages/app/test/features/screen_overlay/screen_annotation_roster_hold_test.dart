// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mark from someone my LiveKit roster has not caught up with waits a few
/// seconds for them, and never shows if they do not join or the call changes.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_call.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

const _carol = VoiceParticipant(
  identity: 'carol',
  name: 'carol',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _sharer = VoiceParticipant(
  identity: 'sharer',
  name: 'sharer',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

final _watching = VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  participants: [rigMe(), _sharer],
);

const _consent = api.CanvasScreenAnnotation(
  channelId: 'call',
  userId: 'sharer',
  targetUserId: 'sharer',
  kind: 'consent',
  points: [],
  ended: false,
  allowed: true,
);

void _join(OverlayRig rig, VoiceParticipant who) =>
    rig.voice.update((s) => s.copyWith(participants: [...s.participants, who]));

/// I watch 'sharer'; 'carol' draws on their screen before my roster shows her.
void _watchCarolDraw(
  FakeAsync async,
  void Function(OverlayRig, ScreenAnnotationFeed) then,
) {
  final rig = OverlayRig(initial: _watching);
  final feed = rig.container.read(screenAnnotationFeedProvider);
  async.flushMicrotasks();
  rig.sync.events.add(_consent);
  rig.annotate(target: 'sharer', from: 'carol');
  async.flushMicrotasks();
  expect(feed.marksFor('sharer'), isEmpty);
  then(rig, feed);
}

void main() {
  group('a viewer\'s feed', () {
    test('shows a mark once its sender joins my roster 2 s later', () {
      fakeAsync((async) {
        _watchCarolDraw(async, (rig, feed) {
          async.elapse(const Duration(seconds: 2));
          _join(rig, _carol);
          async.elapse(Duration.zero);
          expect(feed.marksFor('sharer'), hasLength(1));
        });
      });
    });

    test('drops a mark whose sender never joins my roster', () {
      fakeAsync((async) {
        _watchCarolDraw(async, (rig, feed) {
          async.elapse(rosterGrace + const Duration(seconds: 1));
          _join(rig, _carol);
          async.elapse(Duration.zero);
          expect(feed.marksFor('sharer'), isEmpty);
          expect(feed.boardCount, 0);
        });
      });
    });

    test('drops a held mark when I move to another call', () {
      fakeAsync((async) {
        _watchCarolDraw(async, (rig, feed) {
          rig.voice.update((s) => s.copyWith(channelId: 'other-call'));
          async.elapse(Duration.zero);
          rig.voice.update((s) => s.copyWith(channelId: 'call'));
          _join(rig, _carol);
          async.elapse(Duration.zero);
          expect(feed.marksFor('sharer'), isEmpty);
          expect(feed.boardCount, 0);
        });
      });
    });
  });

  group('the sharer\'s overlay', () {
    test('paints a stamp once its sender joins my roster', () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        rig.stamp(user: 'carol');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(rig.overlay.puts, isEmpty);

        _join(rig, _carol);
        async.flushMicrotasks();
        async.elapse(overlayFrameInterval * 2);
        expect(rig.overlay.puts, ['e:\u{1F389}']);
      });
    });

    test('never paints a stamp from someone who does not join my call', () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        rig.stamp(user: 'carol');
        async.elapse(rosterGrace + const Duration(seconds: 1));
        _join(rig, _carol);
        async.flushMicrotasks();
        async.elapse(overlayFrameInterval * 2);
        expect(rig.stamps.baked, isEmpty);
        expect(rig.overlay.puts, isEmpty);
      });
    });
  });
}
