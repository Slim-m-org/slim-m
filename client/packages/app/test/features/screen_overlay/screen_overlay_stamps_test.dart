// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stamps on the sharer's own screen (decision 0121): consent says this
/// client shows them, each picture crosses to the runner once, and a frame
/// names only pictures the runner holds.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_stamp_timing.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';

import 'overlay_rig.dart';

void main() {
  test('consent tells viewers this client can show stamps', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      expect(rig.sync.sent.single.stamps, isTrue);
    });
  });

  test('turning drawing off says so with no stamps either', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.container
          .read(voiceSettingsControllerProvider.notifier)
          .setScreenShareAllowAnnotations(false);
      async.flushMicrotasks();
      final last = rig.sync.sent.last;
      expect((last.allowed, last.stamps), (false, false));
    });
  });

  test('a stamp is painted once its picture is on the runner, then fades', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp();
      async.flushMicrotasks();
      expect(rig.overlay.puts, ['e:\u{1F389}']);
      async.elapse(annotationStampPop + overlayFrameInterval * 2);
      final stamp = rig.overlay.draws.last.single as OverlayStamp;
      expect(stamp.image, 'e:\u{1F389}');
      expect((stamp.x, stamp.y, stamp.size), (0.4, 0.3, 0.12));
      expect(stamp.scale, 1);
      expect(stamp.alpha, 1);

      async.elapse(annotationStampHold + annotationFade);
      expect(rig.overlay.draws.last, isEmpty);
    });
  });

  test('it pops in: the first frames are smaller than the settled stamp', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp();
      async.flushMicrotasks();
      async.elapse(overlayFrameInterval);
      final first = rig.overlay.draws.first.single as OverlayStamp;
      expect(first.scale, lessThan(1));
    });
  });

  test('a second stamp of the same picture does not send it again', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp();
      rig.stamp(id: 's2');
      async.flushMicrotasks();
      async.elapse(overlayFrameInterval * 2);
      expect(rig.overlay.puts, ['e:\u{1F389}']);
      expect(rig.overlay.draws.last, hasLength(2));
    });
  });

  test('a picture stamp is keyed by its attachment', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp(attachment: 'abc');
      async.flushMicrotasks();
      expect(rig.overlay.puts, ['a:abc']);
    });
  });

  test('a blocked viewer\'s stamp bakes nothing and reaches nothing', () {
    fakeAsync((async) {
      final rig = OverlayRig(blocked: {'viewer'});
      async.flushMicrotasks();
      rig.stamp();
      async.flushMicrotasks();
      async.elapse(overlayFrameInterval * 2);
      expect(rig.stamps.baked, isEmpty);
      expect(rig.overlay.puts, isEmpty);
    });
  });

  test('a stamp sent the moment its sender joined paints at once', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp(user: 'just-joined');
      async.flushMicrotasks();
      async.elapse(overlayFrameInterval * 2);
      expect(rig.overlay.puts, ['e:\u{1F389}']);
      expect(rig.overlay.draws.last.single, isA<OverlayStamp>());
    });
  });

  test('a stamp from another call bakes nothing', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.stamp(channel: 'other-call');
      async.flushMicrotasks();
      async.elapse(overlayFrameInterval * 2);
      expect(rig.stamps.baked, isEmpty);
      expect(rig.overlay.puts, isEmpty);
    });
  });

  test(
    'turning drawing off forgets the pictures, so a new share sends them again',
    () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        rig.stamp();
        async.flushMicrotasks();
        final settings = rig.container.read(
          voiceSettingsControllerProvider.notifier,
        );
        settings.setScreenShareAllowAnnotations(false);
        async.flushMicrotasks();
        settings.setScreenShareAllowAnnotations(true);
        async.flushMicrotasks();
        rig.stamp(id: 's2');
        async.flushMicrotasks();
        expect(rig.overlay.puts, ['e:\u{1F389}', 'e:\u{1F389}']);
      });
    },
  );

  test('a fourth stamp from one viewer starts their first fading', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      for (var i = 1; i <= 4; i++) {
        rig.stamp(id: 's$i');
        async.flushMicrotasks();
      }
      async.elapse(annotationFade + overlayFrameInterval * 2);
      expect(rig.overlay.draws.last, hasLength(maxStampsPerAuthor));
    });
  });

  test('the board kind a stamp parses to', () {
    expect(ScreenAnnotationKind.parse('stamp'), ScreenAnnotationKind.stamp);
  });
}
