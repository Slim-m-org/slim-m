// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the host app knows about iOS screen capture that Dart cannot see.
///
/// iOS is the one platform where a screen share is not something the app does.
/// An app may only capture its own window; everything else is captured by a
/// separate process, a ReplayKit broadcast upload extension, which the system
/// starts on the user's say-so and which hands frames back through a socket in
/// a shared App Group container.
///
/// Two consequences shape this file. Starting a share is a request, not an
/// action, so "the call returned" does not mean anybody is seeing a screen.
/// And a build can be missing the extension entirely, in which case the
/// request can never succeed, which is worth knowing before asking rather
/// than after waiting.
///
/// `BroadcastManager`, LiveKit's own manual-publish escape hatch (see
/// [BroadcastBridge.autoPublishEnabled]), is not in the package's public
/// barrel, so reaching it at all means an `import` of its `src` path.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/managers/broadcast_manager.dart'
    as lk_broadcast;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The seam. The default implementation talks to the app's iOS host; a test
/// supplies its own, which is the only way any of this is exercisable off a
/// device.
abstract class BroadcastBridge {
  /// Whether capture on this platform goes through a broadcast extension at
  /// all. False everywhere but iOS, where the rest of this is moot.
  bool get usesBroadcastExtension;

  /// Whether this build can actually broadcast: the extension named in
  /// Info.plist exists, and the App Group container it shares with the app is
  /// reachable. False means the share control cannot work in this build, no
  /// matter how long anybody waits.
  Future<bool> isAvailable();

  /// Ends a running broadcast. Nothing else can: LiveKit unpublishing the
  /// track leaves ReplayKit recording, red status bar and all.
  Future<void> requestStop();

  /// Whether LiveKit publishes a screen share track on its own the moment a
  /// broadcast starts.
  ///
  /// True is LiveKit's own default and is wrong for this app: it publishes
  /// with whatever `RoomOptions.defaultScreenShareCaptureOptions` says, fixed
  /// at room construction, rather than the quality the user picked moments
  /// before tapping share. Set false before requesting activation and back to
  /// true once this side has published instead; see `screen_share_control.dart`
  /// for the ordering that makes this safe.
  set autoPublishEnabled(bool enabled);

  /// Whenever the platform broadcast starts or stops. Off iOS this never
  /// emits at all, since there is no broadcast to start.
  Stream<bool> get broadcastingChanges;
}

/// Answers over a method channel the iOS host registers in
/// `BroadcastChannel.swift`.
///
/// The broadcast upload extension now exists (target `BroadcastExtension`, its
/// App Group and profile provisioned), so on a correctly signed build
/// [isAvailable] answers true and the share publishes through LiveKit's
/// `BroadcastManager` path - see `screen_share_control.dart` for the sequence
/// that takes manual control of it. A build still missing the extension, or
/// one where the App
/// Group entitlement did not make it into the signature, answers false here
/// and the share control reports [ScreenShareOutcome.unsupported] rather than
/// lighting up over a share nobody could see.
class MethodChannelBroadcastBridge implements BroadcastBridge {
  const MethodChannelBroadcastBridge();

  static const channel = MethodChannel('top.npcserver.slimm/broadcast');

  @override
  bool get usesBroadcastExtension => lk.lkPlatformIs(lk.PlatformType.iOS);

  /// A missing handler answers false rather than throwing: an app build
  /// without this channel has no extension either, which is the same answer.
  @override
  Future<bool> isAvailable() async {
    if (!usesBroadcastExtension) return true;
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'is available failed, ignored', error, stack);
      return false;
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'is available failed, ignored', error, stack);
      return false;
    }
  }

  @override
  Future<void> requestStop() async {
    if (!usesBroadcastExtension) return;
    try {
      await channel.invokeMethod<void>('requestStop');
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'Nothing to stop, or no host to ask. Either way the share is over as far as this side is concerned',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'request stop failed, ignored', error, stack);
      // As above.
    }
  }

  @override
  set autoPublishEnabled(bool enabled) {
    if (!usesBroadcastExtension) return;
    lk_broadcast.BroadcastManager().shouldPublishTrack = enabled;
  }

  @override
  Stream<bool> get broadcastingChanges {
    if (!usesBroadcastExtension) return const Stream.empty();
    final manager = lk_broadcast.BroadcastManager();
    late final StreamController<bool> controller;
    void listener() => controller.add(manager.isBroadcasting);
    controller = StreamController<bool>.broadcast(
      onListen: () => manager.addListener(listener),
      onCancel: () => manager.removeListener(listener),
    );
    return controller.stream;
  }
}
