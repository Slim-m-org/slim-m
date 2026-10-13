// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the iOS broadcast hand-off, with no `lk.Room` involved at all.
///
/// [ScreenShareControl.setEnabled] takes its room access as plain closures
/// rather than a `Room`, precisely so this state machine is testable this
/// way: a fake stream and a list recording what got published say everything
/// a device would otherwise be needed to observe.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

/// One call this fake's `publish` closure recorded.
typedef _PublishCall = (
  bool enabled,
  lk.ScreenShareCaptureOptions? options,
  bool includeAudio,
);

/// Stands in for the iOS host, with a controllable broadcast-state stream a
/// test can push through by hand.
class _FakeBridge implements BroadcastBridge {
  _FakeBridge({this.usesBroadcastExtension = true, this.available = true});

  @override
  final bool usesBroadcastExtension;
  final bool available;

  /// Every write to [autoPublishEnabled], in order, so a test can assert both
  /// that it happened and when relative to a publish call.
  final autoPublishWrites = <bool>[];
  int stopRequests = 0;

  final _broadcasting = StreamController<bool>.broadcast();

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestStop() async => stopRequests++;

  @override
  set autoPublishEnabled(bool enabled) => autoPublishWrites.add(enabled);

  @override
  Stream<bool> get broadcastingChanges => _broadcasting.stream;

  /// Simulates the user tapping Start Broadcast in the system picker.
  void startBroadcasting() => _broadcasting.add(true);

  Future<void> dispose() => _broadcasting.close();
}

void main() {
  group('the iOS hand-off', () {
    late _FakeBridge bridge;
    late ScreenShareControl control;
    final calls = <_PublishCall>[];
    var sharing = false;
    final settled = <Object?>[];
    var settledCount = 0;

    setUp(() {
      bridge = _FakeBridge();
      control = ScreenShareControl(bridge);
      calls.clear();
      sharing = false;
      settled.clear();
      settledCount = 0;
    });

    tearDown(() => bridge.dispose());

    Future<void> publish(
      bool enabled,
      lk.ScreenShareCaptureOptions? o,
      bool audio,
    ) async {
      calls.add((enabled, o, audio));
    }

    Future<ScreenShareOutcome> start() => control.setEnabled(
          true,
          quality: ScreenShareQuality(
              ScreenShareResolution.p1440, ScreenShareFps.fps15),
          publish: publish,
          isSharing: () => sharing,
          onSettled: (e) {
            settledCount++;
            settled.add(e);
          },
        );

    test('disarms LiveKit\'s own republish before requesting the picker',
        () async {
      // Left at its default, a native notification would republish with LiveKit's own defaults.
      final outcome = await start();

      expect(outcome, ScreenShareOutcome.pendingBroadcast);
      expect(bridge.autoPublishWrites.first, isFalse,
          reason: 'must be disarmed before the first publish, not after');
    });

    test('publishes nothing until the broadcast actually starts', () async {
      await start();
      expect(calls, hasLength(1),
          reason: 'only the request that shows the picker so far');

      bridge.startBroadcasting();
      await pumpEventQueue();

      expect(calls, hasLength(2),
          reason: 'the broadcast starting is what triggers the real publish');
    });

    test('the deferred publish carries this call\'s own capture options',
        () async {
      // The bug this file exists to catch: a null options here means LiveKit's own fixed default.
      await start();
      bridge.startBroadcasting();
      await pumpEventQueue();

      final options = calls.last.$2;
      expect(options, isNotNull);
      expect(options!.useiOSBroadcastExtension, isTrue);
      // Frame rate, not size: size is capped on iOS so every tier shares it.
      expect(
          options.params.encoding!.maxFramerate,
          ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
              .fps,
          reason: 'must be this call\'s quality, not a default');
    });

    test('the deferred publish also carries this call\'s own audio choice',
        () async {
      // Never true on iOS today, but the hand-off's plumbing must not drop it if it were.
      await control.setEnabled(
        true,
        quality: ScreenShareQuality(
            ScreenShareResolution.p1440, ScreenShareFps.fps15),
        includeAudio: true,
        publish: publish,
        isSharing: () => sharing,
        onSettled: (e) {},
      );
      bridge.startBroadcasting();
      await pumpEventQueue();

      expect(calls.last.$3, isTrue);
    });

    test('reports success through onSettled once the deferred publish lands',
        () async {
      await start();
      bridge.startBroadcasting();
      await pumpEventQueue();

      expect(settledCount, 1);
      expect(settled.single, isNull);
    });

    test('restores auto-publish only after the deferred publish, not before',
        () async {
      await start();
      expect(bridge.autoPublishWrites, [false],
          reason: 'still disarmed while nothing has published yet');

      bridge.startBroadcasting();
      await pumpEventQueue();

      expect(bridge.autoPublishWrites, [false, true],
          reason: 'restored is the last write, made after the publish '
              'landed, or a later native notification could unpublish the '
              'track this call just created');
    });

    test('a deferred publish that throws is reported and still restores',
        () async {
      calls.clear();
      var attempt = 0;
      final failing = ScreenShareControl(bridge);
      final outcome = await failing.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        publish: (enabled, o, audio) async {
          attempt++;
          if (attempt == 2) throw StateError('capture refused');
        },
        isSharing: () => sharing,
        onSettled: (e) {
          settledCount++;
          settled.add(e);
        },
      );
      expect(outcome, ScreenShareOutcome.pendingBroadcast);

      bridge.startBroadcasting();
      await pumpEventQueue();

      expect(settledCount, 1);
      expect(settled.single, isA<StateError>());
      expect(bridge.autoPublishWrites.last, isTrue,
          reason: 'a failed publish must not leave the flag disarmed');
    });

    test('already broadcasting publishes directly with nothing to hand off',
        () async {
      // A resumed session: LiveKit never took the requestActivation branch at all.
      final direct = ScreenShareControl(bridge);
      final outcome = await direct.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        publish: (enabled, o, audio) async {
          calls.add((enabled, o, audio));
          sharing = true;
        },
        isSharing: () => sharing,
        onSettled: (e) => settled.add(e),
      );

      expect(outcome, ScreenShareOutcome.started);
      expect(bridge.autoPublishWrites, [false, true]);

      // Nothing was armed, so a later native notification must not reach a second publish.
      bridge.startBroadcasting();
      await pumpEventQueue();
      expect(calls, hasLength(1));
    });

    test('disabling while still awaiting the picker cancels the hand-off',
        () async {
      await start();
      expect(bridge.autoPublishWrites, [false]);

      final stopped = await control.setEnabled(
        false,
        quality: ScreenShareQuality.standard,
        publish: publish,
        isSharing: () => sharing,
        onSettled: (e) => settled.add(e),
      );
      expect(stopped, ScreenShareOutcome.stopped);
      expect(bridge.stopRequests, 1);
      expect(bridge.autoPublishWrites.last, isTrue,
          reason: 'cancelling must not leave the flag disarmed for the next '
              'share attempt');

      // The picker being answered after cancellation must reach nothing.
      calls.clear();
      bridge.startBroadcasting();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test(
        'disposing mid-request cancels the hand-off and still asks the '
        'platform to stop, in case the picker was answered just before',
        () async {
      await start();
      expect(bridge.stopRequests, 0);

      await control.dispose();

      expect(bridge.stopRequests, 1,
          reason: 'a call ending must not leave the phone still recording, '
              'whether or not this hand-off ever reached a real broadcast');
      expect(bridge.autoPublishWrites.last, isTrue,
          reason: 'disposing must not leave the flag disarmed past this call');

      // The picker being answered after disposal must reach nothing.
      calls.clear();
      bridge.startBroadcasting();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });

    test('disposing with no share ever requested is still safe', () async {
      final idle = ScreenShareControl(bridge);
      await idle.dispose();
      expect(bridge.stopRequests, 1,
          reason: 'requestStop is unconditional; a call with no share at all '
              'reaches nobody on the other end of it');
    });

    test('a second request cancels the first hand-off rather than stacking',
        () async {
      await start();
      await start();
      bridge.startBroadcasting();
      await pumpEventQueue();

      // Two requests to show the picker, but a stale listener must not also fire.
      expect(calls, hasLength(3));
      expect(settledCount, 1);
    });

    test('a build with no working extension is refused before any of this',
        () async {
      final unsupported = _FakeBridge(available: false);
      final control = ScreenShareControl(unsupported);
      final outcome = await control.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        publish: publish,
        isSharing: () => false,
        onSettled: (e) => settled.add(e),
      );
      expect(outcome, ScreenShareOutcome.unsupported);
      expect(unsupported.autoPublishWrites, isEmpty,
          reason: 'nothing to disarm when the request is refused up front');
      await unsupported.dispose();
    });
  });

  group('off iOS', () {
    test('publishes directly with no hand-off at all', () async {
      final bridge = _FakeBridge(usesBroadcastExtension: false);
      final control = ScreenShareControl(bridge);
      final calls = <_PublishCall>[];

      final outcome = await control.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        sourceId: 'screen-1',
        publish: (enabled, o, audio) async => calls.add((enabled, o, audio)),
        isSharing: () => true,
        onSettled: (e) {},
      );

      expect(outcome, ScreenShareOutcome.started);
      expect(calls.single.$2!.useiOSBroadcastExtension, isFalse);
      expect(calls.single.$2!.deviceId, 'screen-1');
      expect(calls.single.$3, isFalse,
          reason: 'nobody asked for audio, so nothing is requested');
      expect(bridge.autoPublishWrites, isEmpty,
          reason: 'a platform with no broadcast extension has nothing to '
              'disarm');
      await bridge.dispose();
    });

    test('a request for audio reaches the publish closure unchanged', () async {
      final bridge = _FakeBridge(usesBroadcastExtension: false);
      final control = ScreenShareControl(bridge);
      final calls = <_PublishCall>[];

      await control.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        includeAudio: true,
        publish: (enabled, o, audio) async => calls.add((enabled, o, audio)),
        isSharing: () => true,
        onSettled: (e) {},
      );

      expect(calls.single.$3, isTrue,
          reason: 'this is what the caller asked for; a fake session '
              'dropping it here would drop it on web and Linux too');
      await bridge.dispose();
    });

    test('a synchronous failure reports its cause through onSettled', () async {
      final bridge = _FakeBridge(usesBroadcastExtension: false);
      final control = ScreenShareControl(bridge);
      Object? reported;

      final outcome = await control.setEnabled(
        true,
        quality: ScreenShareQuality.standard,
        publish: (enabled, o, audio) async => throw StateError('refused'),
        isSharing: () => false,
        onSettled: (e) => reported = e,
      );

      expect(outcome, ScreenShareOutcome.failed);
      expect(reported, isA<StateError>());
      await bridge.dispose();
    });
  });

  group('capture options', () {
    test('the chosen screen reaches LiveKit as its device id', () {
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality.standard,
        'screen-2',
        isIOS: false,
      );

      // LiveKit carries sourceId as deviceId; dropped, a desktop share cannot start.
      expect(options.deviceId, 'screen-2');
    });

    test('no source named is left unset rather than defaulted', () {
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality.standard,
        null,
        isIOS: false,
      );

      expect(options.deviceId, isNull);
    });

    test('off iOS the flag is false and the real source id survives', () {
      // A desktop share names its own screen; isIOS must never clobber it.
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality.standard,
        'screen-2',
        isIOS: false,
      );

      expect(options.useiOSBroadcastExtension, isFalse);
      expect(options.deviceId, 'screen-2');
    });

    test('on iOS the flag is true and the device id is the broadcast hint', () {
      // Without this hint LiveKit's second pass starts its own broadcast, "already broadcasting".
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality.standard,
        null,
        isIOS: true,
      );

      expect(options.useiOSBroadcastExtension, isTrue);
      expect(options.deviceId, 'broadcast-manual');
    });

    /// A broadcast upload extension has 50 MB and iOS kills it past that,
    /// which a user sees as the same "Screen Recording has stopped" alert a
    /// failed start gives. So an over-large capture is not a quality question
    /// on this platform, it is the difference between sharing and not.
    test('every iOS tier is bounded to one phone-sized capture', () {
      for (final quality in ScreenShareQuality.all) {
        final options = ScreenShareControl.captureOptionsFor(
          quality,
          null,
          isIOS: true,
        );

        expect(
          options.params.dimensions.width,
          720,
          reason: '${quality.id} must not widen an iOS capture',
        );
        expect(options.params.dimensions.height, 1280);
      }
    });

    /// The cap is on size alone. A tier that changed nothing at all would be
    /// a control that cannot change anything, which is worse than no control.
    test('an iOS tier still decides frame rate and bitrate', () {
      final smooth = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps60),
        null,
        isIOS: true,
      );
      final crisp = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15),
        null,
        isIOS: true,
      );

      expect(
          smooth.params.encoding!.maxFramerate,
          ScreenShareQuality(ScreenShareResolution.p720, ScreenShareFps.fps60)
              .fps);
      expect(
          crisp.params.encoding!.maxFramerate,
          ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
              .fps);
      expect(
        smooth.params.encoding!.maxBitrate,
        isNot(crisp.params.encoding!.maxBitrate),
      );
    });

    /// Desktop is the platform the landscape tiers were written for, and it
    /// has no extension and no 50 MB budget.
    test('off iOS the chosen tier still sets the capture size', () {
      final options = ScreenShareControl.captureOptionsFor(
        ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15),
        'screen-1',
        isIOS: false,
      );

      expect(
          options.params.dimensions.width,
          ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
              .width);
      expect(
          options.params.dimensions.height,
          ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)
              .height);
    });
  });
}
