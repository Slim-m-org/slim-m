// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call panel on the overlay window: shown by setting, call and share
/// state, listing the people in the call, and silent when nothing changed.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

VoiceParticipant _person(
  String name, {
  bool local = false,
  bool speaking = false,
  bool muted = false,
  bool deafened = false,
  double level = 0,
}) => VoiceParticipant(
  identity: name,
  name: name,
  isSpeaking: speaking,
  isMuted: muted,
  isLocal: local,
  isScreenSharing: false,
  isDeafened: deafened,
  audioLevel: level,
);

VoiceState _call(List<VoiceParticipant> people, {bool sharing = false}) =>
    VoiceState(
      channelId: 'call',
      state: VoiceSessionState.connected,
      screenSharing: sharing,
      participants: people,
    );

final _pair = [_person('me', local: true), _person('web')];

OverlayRig _rig({
  List<VoiceParticipant>? people,
  bool allow = false,
  bool callOverlay = true,
  OverlayCorner corner = OverlayCorner.topLeft,
  bool supported = true,
  bool sharing = false,
  ScreenShareSource? source,
}) => OverlayRig(
  allow: allow,
  callOverlay: callOverlay,
  corner: corner,
  supported: supported,
  initial: _call(people ?? _pair, sharing: sharing),
  source: source,
);

OverlayPanel _lastPanel(OverlayRig rig) => rig.overlay.panels.last!;

/// Riverpod hands a changed provider to its listeners on the next timer turn, which flushing microtasks alone does not reach.
void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

void main() {
  test('off by default: no window and no panel', () {
    fakeAsync((async) {
      final rig = _rig(callOverlay: false);
      async.flushMicrotasks();
      expect(rig.overlay.shown, isEmpty);
      expect(rig.overlay.panels, isEmpty);
    });
  });

  test(
    'in a call with the setting on: the panel goes on the primary monitor',
    () {
      fakeAsync((async) {
        final rig = _rig();
        async.flushMicrotasks();
        expect(rig.overlay.shown, [
          [0],
        ]);
        expect(rig.active, isFalse);
        final panel = _lastPanel(rig);
        expect((panel.monitor, panel.corner), (0, OverlayCorner.topLeft));
        expect(panel.rows.map((r) => r.name), ['me (you)', 'web']);
      });
    },
  );

  test('the monitor the app window is on wins when the runner can tell', () {
    fakeAsync((async) {
      final rig = _rig();
      rig.overlay.appMonitorIndex = 1;
      async.flushMicrotasks();
      expect(rig.overlay.shown, [
        [1],
      ]);
      expect(_lastPanel(rig).monitor, 1);
    });
  });

  test('the chosen corner is sent, and changing it repaints', () {
    fakeAsync((async) {
      final rig = _rig(corner: OverlayCorner.bottomRight);
      async.flushMicrotasks();
      expect(_lastPanel(rig).corner, OverlayCorner.bottomRight);
      unawaited(
        rig.container
            .read(voiceSettingsControllerProvider.notifier)
            .setCallOverlayCorner(OverlayCorner.topRight),
      );
      _settle(async);
      expect(_lastPanel(rig).corner, OverlayCorner.topRight);
      expect(rig.overlay.panels.length, 2);
    });
  });

  test('speaking and mute show on the rows', () {
    fakeAsync((async) {
      final rig = _rig();
      async.flushMicrotasks();
      rig.voice.set(
        _call([
          _person('me', local: true, muted: true),
          _person('web', speaking: true),
          _person('deaf', deafened: true),
        ]),
      );
      _settle(async);
      final rows = _lastPanel(rig).rows;
      expect((rows[0].muted, rows[0].speaking), (true, false));
      expect((rows[1].speaking, rows[1].muted), (true, false));
      expect(rows[2].deafened, isTrue);
    });
  });

  test('nothing is sent while nothing a row shows has changed', () {
    fakeAsync((async) {
      final rig = _rig();
      async.flushMicrotasks();
      final sent = rig.overlay.panels.length;
      rig.voice.set(
        _call([_person('me', local: true, level: 0.4), _person('web')]),
      );
      _settle(async);
      rig.voice.set(
        _call([_person('me', local: true, level: 0.9), _person('web')]),
      );
      _settle(async);
      async.elapse(const Duration(seconds: 5));
      expect(rig.overlay.panels.length, sent);
    });
  });

  test('a big call shows eight rows and counts the rest', () {
    fakeAsync((async) {
      final rig = _rig(
        people: [
          _person('me', local: true),
          for (var i = 0; i < 11; i++) _person('p$i'),
        ],
      );
      async.flushMicrotasks();
      final panel = _lastPanel(rig);
      expect(panel.rows.length, 8);
      expect(panel.more, 4);
      expect(panel.rows.first.name, 'me (you)');
    });
  });

  test('sharing a whole screen hides the panel', () {
    fakeAsync((async) {
      final rig = _rig();
      async.flushMicrotasks();
      expect(rig.overlay.hides, 0);
      rig.voice.set(_call(_pair, sharing: true));
      _settle(async);
      expect(rig.overlay.hides, 1);
      final shownAfter = rig.overlay.shown.length;
      rig.voice.set(_call(_pair));
      _settle(async);
      expect(rig.overlay.shown.length, shownAfter + 1);
      expect(rig.overlay.panels.length, 2);
    });
  });

  test(
    'a whole-screen share with drawing allowed hands the window to drawing',
    () {
      fakeAsync((async) {
        final rig = _rig(allow: true);
        async.flushMicrotasks();
        rig.voice.set(_call(_pair, sharing: true));
        _settle(async);
        expect(rig.active, isTrue);
        expect(rig.overlay.shown.last, [0, 1]);
        final panels = rig.overlay.panels.length;
        rig.voice.set(
          _call([_person('me', local: true, muted: true)], sharing: true),
        );
        _settle(async);
        expect(rig.overlay.panels.length, panels);
        rig.voice.set(_call(_pair));
        _settle(async);
        expect(rig.active, isFalse);
        expect(rig.overlay.shown.last, [0]);
        expect(rig.overlay.panels.length, panels + 1);
      });
    },
  );

  test('a window share keeps the panel', () {
    fakeAsync((async) {
      final rig = _rig(
        sharing: true,
        source: const ScreenShareSource(
          id: 'w',
          name: 'Editor',
          isWindow: true,
        ),
      );
      async.flushMicrotasks();
      expect(rig.overlay.panels, isNotEmpty);
      expect(rig.overlay.hides, 0);
    });
  });

  test('leaving the call or turning the setting off clears the window', () {
    fakeAsync((async) {
      final rig = _rig();
      async.flushMicrotasks();
      rig.voice.set(const VoiceState());
      _settle(async);
      expect(rig.overlay.hides, 1);
      rig.voice.set(_call(_pair));
      _settle(async);
      unawaited(
        rig.container
            .read(voiceSettingsControllerProvider.notifier)
            .setCallOverlayEnabled(false),
      );
      _settle(async);
      expect(rig.overlay.hides, 2);
    });
  });

  test('a desktop that cannot host the overlay never opens it', () {
    fakeAsync((async) {
      final rig = _rig(supported: false);
      async.flushMicrotasks();
      expect(rig.overlay.shown, isEmpty);
      expect(rig.overlay.panels, isEmpty);
    });
  });
}
