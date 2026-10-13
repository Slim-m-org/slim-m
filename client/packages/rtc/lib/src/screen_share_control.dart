// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starting and stopping a screen share, and the iOS hand-off that makes it
/// publish with the quality the user actually picked.
///
/// Split out of `voice_session.dart` for two reasons. It was the file's
/// obvious seam already (neither this nor [BroadcastBridge] depends on the
/// rest of a session's state), and `voice_session.dart` sat one edit away
/// from the project's 500-line hard ceiling before this file's own logic
/// grew large enough to need a place of its own.
///
/// [ScreenSharePublish] and the `isSharing` callback [setEnabled] takes are
/// plain closures rather than a `lk.Room`, on purpose: the iOS sequence below
/// is a state machine worth testing directly, and a fake closure is a great
/// deal less to stand up in a test than a room with a working
/// `localParticipant`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'broadcast_bridge.dart';
import 'screen_share.dart';

/// Publishes or unpublishes a screen share track with the given options.
/// `options` is null when disabling. `includeAudio` is [setEnabled]'s own
/// parameter of the same name, carried through so a caller can pass it on to
/// LiveKit's own top-level `captureScreenAudio` publish flag - see
/// `screen_share_audio.dart` for why that is the parameter that matters, not
/// a field on `options`.
typedef ScreenSharePublish = Future<void> Function(
  bool enabled,
  lk.ScreenShareCaptureOptions? options,
  bool includeAudio,
);

/// Runs one [VoiceSession]'s screen share: the ceiling checks, the platform
/// availability check, and on iOS the hand-off described below.
///
/// iOS publishes a screen share in two acts nothing here controls the timing
/// of. `BroadcastManager.requestActivation()` only shows the system picker;
/// the broadcast itself starts, if it does, whenever the user taps Start
/// Broadcast, arbitrarily long after this returns. LiveKit's own answer to
/// that gap is to republish automatically the moment broadcasting begins,
/// using `RoomOptions.defaultScreenShareCaptureOptions` - fixed at room
/// construction - rather than whatever quality this call was asked for. Left
/// alone, that means the quality ceiling the app applies to every share (see
/// `voice_call_controls.dart`) is a setting that cannot change anything on
/// iOS.
///
/// The fix is LiveKit's own documented escape hatch,
/// `BroadcastManager.shouldPublishTrack`. [setEnabled] sets it false before
/// requesting activation, so the automatic republish becomes a harmless
/// no-op (`_broadcastStateChanged` computes `isBroadcasting &&
/// shouldPublishTrack`, which is false either way while nothing is
/// published), waits for [BroadcastBridge.broadcastingChanges] to report the
/// broadcast actually starting, and only then publishes itself with this
/// call's own options. Restoring `shouldPublishTrack` to true happens after
/// that publish succeeds or fails, never before: while it is false a second
/// native notification resolves to nothing, but once it is back to true the
/// same notification resolves to `unmute()` on the publication this class
/// just created rather than a second, option-less publish clobbering it.
class ScreenShareControl {
  ScreenShareControl(this._broadcast);

  final BroadcastBridge _broadcast;

  /// The iOS hand-off in progress, if a share is still waiting on the system
  /// picker. Held so a second call - a rapid re-tap, or disabling while
  /// pending - cancels it rather than stacking a second listener underneath.
  StreamSubscription<bool>? _handoff;

  /// Starts or stops the share. See the class doc for the iOS sequence;
  /// every other platform publishes (or unpublishes) directly and returns.
  ///
  /// [onSettled] carries the cause of any failure, immediate or deferred:
  /// `null` on success, the error otherwise. It is called synchronously for
  /// every platform but iOS, where a [ScreenShareOutcome.pendingBroadcast]
  /// result means it fires later instead, once the deferred publish succeeds
  /// or fails; there is nothing to call it for a second time when the
  /// immediate result already said `failed`.
  Future<ScreenShareOutcome> setEnabled(
    bool enabled, {
    required ScreenShareQuality quality,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
    required ScreenSharePublish publish,
    required bool Function() isSharing,
    required void Function(Object? error) onSettled,
  }) async {
    await _cancelHandoff();
    if (enabled && !await _broadcast.isAvailable()) {
      return ScreenShareOutcome.unsupported;
    }
    final onIOS = _broadcast.usesBroadcastExtension;
    try {
      if (enabled && onIOS) {
        return await _startOnIOS(
          quality: quality,
          sourceId: sourceId,
          includeAudio: includeAudio,
          maxHeight: maxHeight,
          publish: publish,
          isSharing: isSharing,
          onSettled: onSettled,
        );
      }
      await publish(
        enabled,
        enabled
            ? captureOptionsFor(
                quality,
                sourceId,
                isIOS: onIOS,
                maxHeight: maxHeight,
              )
            : null,
        includeAudio,
      );
      if (!enabled) await _broadcast.requestStop();
      if (!enabled) return ScreenShareOutcome.stopped;
      return isSharing()
          ? ScreenShareOutcome.started
          : ScreenShareOutcome.pendingBroadcast;
    } catch (e) {
      onSettled(e);
      return ScreenShareOutcome.failed;
    }
  }

  /// The iOS-only act one of [setEnabled]: disarm LiveKit's own republish,
  /// ask for the system picker, and either publish immediately (a broadcast
  /// already running) or arm a listener for the moment one starts.
  Future<ScreenShareOutcome> _startOnIOS({
    required ScreenShareQuality quality,
    required String? sourceId,
    required bool includeAudio,
    required int? maxHeight,
    required ScreenSharePublish publish,
    required bool Function() isSharing,
    required void Function(Object? error) onSettled,
  }) async {
    _broadcast.autoPublishEnabled = false;
    final options = captureOptionsFor(
      quality,
      sourceId,
      isIOS: true,
      maxHeight: maxHeight,
    );
    try {
      await publish(true, options, includeAudio);
    } catch (e) {
      _broadcast.autoPublishEnabled = true;
      onSettled(e);
      return ScreenShareOutcome.failed;
    }
    if (isSharing()) {
      // Already broadcasting (a resumed session, most likely): nothing left to arm.
      _broadcast.autoPublishEnabled = true;
      return ScreenShareOutcome.started;
    }
    _armHandoff(options, includeAudio, publish, onSettled);
    return ScreenShareOutcome.pendingBroadcast;
  }

  /// Waits for the broadcast to actually start, then publishes with the
  /// options this share was asked for. A no-op if the user never starts it
  /// or later cancels the share; see the class doc for why that is not
  /// reported as a failure.
  void _armHandoff(
    lk.ScreenShareCaptureOptions options,
    bool includeAudio,
    ScreenSharePublish publish,
    void Function(Object? error) onSettled,
  ) {
    late final StreamSubscription<bool> sub;
    sub = _broadcast.broadcastingChanges.listen((broadcasting) {
      if (!broadcasting) return;
      unawaited(sub.cancel());
      // Stale: `_cancelHandoff` already moved on, so this subscription is no longer wanted.
      if (!identical(_handoff, sub)) return;
      _handoff = null;
      unawaited(
        _publishAfterActivation(options, includeAudio, publish, onSettled),
      );
    });
    _handoff = sub;
  }

  Future<void> _publishAfterActivation(
    lk.ScreenShareCaptureOptions options,
    bool includeAudio,
    ScreenSharePublish publish,
    void Function(Object? error) onSettled,
  ) async {
    try {
      await publish(true, options, includeAudio);
      onSettled(null);
    } catch (e) {
      onSettled(e);
    } finally {
      _broadcast.autoPublishEnabled = true;
    }
  }

  /// Cancels a hand-off still waiting on the picker, restoring LiveKit's own
  /// republish so a build never gets stuck with it disarmed. Safe to call
  /// with nothing pending.
  Future<void> _cancelHandoff() async {
    final sub = _handoff;
    _handoff = null;
    if (sub == null) return;
    await sub.cancel();
    _broadcast.autoPublishEnabled = true;
  }

  /// Ends a running platform broadcast outright. Unpublishing the LiveKit
  /// track (which [VoiceSession]'s own room teardown already does on every
  /// path) only removes it from the call - it does not tell iOS's ReplayKit
  /// extension to stop recording; see [BroadcastBridge.requestStop]'s own
  /// doc comment, which already named this as the one thing nothing else can
  /// do. Safe to call whether or not a share was ever active: off iOS, and
  /// with nothing broadcasting, the request reaches nobody.
  ///
  /// [VoiceSession] awaits this explicitly, first, before it does anything
  /// that could be read as "the call is ending" - the room disconnecting has
  /// no bearing on whether iOS is still recording, so this can never be an
  /// afterthought folded into a later cleanup step.
  Future<void> stopActiveBroadcast() => _broadcast.requestStop();

  /// Called from [VoiceSession]'s own teardown as a backstop, after
  /// [stopActiveBroadcast] has already run on every path this package knows
  /// about. Cancels a hand-off still waiting on the picker, so leaving
  /// mid-request cannot leave a listener running or `autoPublishEnabled`
  /// stuck false past the call that set it, and asks the platform to stop
  /// again in case some future call-ending path is added that reaches
  /// disposal without going through the ordered call first.
  Future<void> dispose() async {
    await _cancelHandoff();
    await stopActiveBroadcast();
  }

  /// The capture options a share is published with.
  ///
  /// Extracted so the [sourceId] hand-off is assertable: it reaches LiveKit as
  /// `deviceId`, and dropping it is what made a desktop share fail with
  /// `source not found!` while every other setting looked right.
  ///
  /// [lk.ScreenShareCaptureOptions.useiOSBroadcastExtension] is the load-bearing
  /// flag on iOS: it is what tells flutter_webrtc's `getDisplayMedia` to join
  /// the broadcast already running rather than start one of its own, which is
  /// what "already broadcasting" meant before this flag was ever set.
  ///
  /// [isIOS] is the platform seam, mirroring how [DesktopSources] is injected
  /// on [VoiceSession]: null (the production default) asks the real platform,
  /// and a test supplies its own so both branches are assertable. The
  /// `broadcast-manual` device id is set here, on [isIOS], rather than left to
  /// LiveKit's own downstream substitution, which re-asks the real platform
  /// and so cannot be driven by a fake.
  ///
  /// [maxHeight] is the space-wide screen-share ceiling (see
  /// `Store::screen_share_max_height` on the server); `null` leaves every
  /// tier's own dimensions untouched. Enforcement is entirely client-side:
  /// this is the one place a chosen quality's height is actually bounded
  /// before publish, on every platform including iOS, whose own capture is
  /// otherwise a fixed size unrelated to the tier picked.
  @visibleForTesting
  static lk.ScreenShareCaptureOptions captureOptionsFor(
    ScreenShareQuality quality,
    String? sourceId, {
    bool? isIOS,
    int? maxHeight,
  }) {
    final onIOS = isIOS ?? lk.lkPlatformIs(lk.PlatformType.iOS);
    final dimensions = onIOS
        ? _boundedDimensions(
            _iosCaptureShortEdge, _iosCaptureLongEdge, maxHeight)
        : _boundedDimensions(quality.width, quality.height, maxHeight);
    return lk.ScreenShareCaptureOptions(
      useiOSBroadcastExtension: onIOS,
      sourceId: onIOS ? _iosBroadcastManualDeviceId : sourceId,
      maxFrameRate: quality.fps.toDouble(),
      params: lk.VideoParameters(
        dimensions: dimensions,
        encoding: lk.VideoEncoding(
          maxBitrate: quality.maxBitrate,
          maxFramerate: quality.fps,
        ),
      ),
    );
  }

  /// LiveKit's own hint for the `BroadcastManager`'s second pass; see
  /// [captureOptionsFor].
  static const _iosBroadcastManualDeviceId = 'broadcast-manual';

  /// The capture size every iOS share is bounded to, whatever tier was picked.
  ///
  /// A broadcast upload extension gets 50 MB of memory and iOS kills it when
  /// it goes over, which surfaces to the person sharing as the same "Screen
  /// Recording has stopped" alert a failed start gives - so the failure this
  /// prevents is indistinguishable, to a user, from the one the rest of this
  /// class fixes. Twilio's own iOS guidance says their SDK exceeds that budget
  /// capturing retina screens and that they downscale to stay inside it.
  ///
  /// Portrait, and short edge first, because the source is a phone held
  /// upright rather than a desktop: [ScreenShareQuality]'s landscape figures
  /// describe a monitor, and the widest of them asks to upscale a roughly
  /// 1290-point-wide screen to 2560, which buys nothing and costs buffer.
  ///
  /// The tier still decides frame rate and bitrate, which are the knobs that
  /// mean something on a phone. Only the dimensions are overridden, so a
  /// choice made in the share dialog still changes what is published.
  static const _iosCaptureShortEdge = 720;
  static const _iosCaptureLongEdge = 1280;

  /// [height] clamped to [maxHeight], scaling [width] to hold the same
  /// aspect ratio. Returns the pair unchanged whenever there is no ceiling or
  /// [height] is already inside it, so a deployment that never lowers the
  /// ceiling below [ScreenShareQuality(ScreenShareResolution.p1440, ScreenShareFps.fps15)]'s own height publishes exactly
  /// what it always has.
  static lk.VideoDimensions _boundedDimensions(
    int width,
    int height,
    int? maxHeight,
  ) {
    if (maxHeight == null || height <= maxHeight) {
      return lk.VideoDimensions(width, height);
    }
    final scaledWidth = (width * maxHeight / height).round();
    return lk.VideoDimensions(scaledWidth, maxHeight);
  }
}
