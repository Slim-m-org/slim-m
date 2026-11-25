// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overlay window and its timers do not outlive their controller, and a
/// panel the runner refused is sent again.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/overlay_marks.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

VoiceParticipant _person(String name, {bool local = false}) => VoiceParticipant(
  identity: name,
  name: name,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

class _SlowPut extends FakeOverlay {
  final reply = Completer<bool>();

  @override
  Future<bool> putImage(String key, Uint8List png) => reply.future;
}

void main() {
  test('a call panel opened as the controller is disposed is hidden again', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        allow: false,
        callOverlay: true,
        initial: VoiceState(
          channelId: 'call',
          state: VoiceSessionState.connected,
          participants: [_person('me', local: true), _person('web')],
        ),
      );
      rig.overlay.showHold = Completer<void>();
      async.flushMicrotasks();
      expect(rig.overlay.shown, isNotEmpty);
      rig.container.dispose();
      rig.overlay.showHold!.complete();
      async.flushMicrotasks();
      expect(rig.overlay.hides, greaterThan(0));
    });
  });

  test(
    'a share overlay opened as the controller is disposed is hidden again',
    () {
      fakeAsync((async) {
        final rig = OverlayRig();
        rig.overlay.showHold = Completer<void>();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(rig.overlay.shown, isNotEmpty);
        rig.container.dispose();
        rig.overlay.showHold!.complete();
        async.flushMicrotasks();
        expect(rig.overlay.hides, greaterThan(0));
      });
    },
  );

  test('a panel the runner refused is sent again with its pictures', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        allow: false,
        callOverlay: true,
        initial: VoiceState(
          channelId: 'call',
          state: VoiceSessionState.connected,
          participants: [_person('me', local: true), _person('web')],
        ),
      );
      rig.overlay.panelWorks = false;
      rig.setAvatar('web', 1);
      _settle(async);
      final refused = rig.overlay.panels.length;
      expect(refused, greaterThan(0));
      rig.overlay.panelWorks = true;
      rig.setAvatar('me', 1);
      _settle(async);
      final resent = rig.overlay.panels.skip(refused).whereType<OverlayPanel>();
      expect(resent, isNotEmpty);
      final web = resent.last.rows.firstWhere((r) => r.id == 'web');
      expect(web.avatar, isNotNull, reason: 'the picture was never delivered');
    });
  });

  test('a stamp picture landing after dispose starts no repaint timer', () {
    fakeAsync((async) {
      final window = _SlowPut();
      final now = DateTime(2026);
      final marks = OverlayMarks(
        window,
        clock: () => now,
        stamps: () => RigStampImages(),
      );
      marks.add(
        const api.CanvasScreenAnnotation(
          channelId: 'call',
          userId: 'viewer',
          targetUserId: 'me',
          kind: 'stamp',
          annotationId: 's1',
          points: [0.4, 0.3],
          size: 0.12,
          emoji: '\u{1F389}',
          ended: true,
          allowed: false,
        ),
      );
      async.flushMicrotasks();
      marks.dispose();
      window.reply.complete(true);
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
