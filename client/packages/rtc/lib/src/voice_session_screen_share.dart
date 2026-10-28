// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen-share half of a voice session, apart from the call lifecycle.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:livekit_client/livekit_client.dart' as lk;

import 'broadcast_bridge.dart';
import 'desktop_sources.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

import 'screen_share.dart';
import 'screen_share_audio_mute.dart';
import 'screen_share_control.dart';
import 'screen_share_local.dart';
import 'screen_share_publish.dart';
import 'screen_share_source_size.dart';
import 'screen_share_watch.dart';
import 'screen_share_view.dart';
import 'share_audio_isolation.dart';
import 'voice_roster_snapshot.dart';

/// Runs [run]; a failure is reported, handed to [noteError], and answered with
/// [fallback] so a picker or toggle never throws into the UI.
Future<T> runReported<T>(
  String action,
  T fallback,
  Future<T> Function() run,
  void Function(Object error) noteError,
) async {
  try {
    return await run();
  } catch (e, stack) {
    reportFailure(LogTag.voice, action, e, stack);
    noteError(e);
    return fallback;
  }
}

/// What a [VoiceScreenShare] needs from the session that owns it.
class VoiceScreenShareHost {
  const VoiceScreenShareHost({
    required this.room,
    required this.noteError,
    required this.refresh,
    required this.reported,
  });

  final lk.Room? Function() room;
  final void Function(Object error) noteError;
  final void Function() refresh;
  final Future<T> Function<T>(
      String action, T fallback, Future<T> Function() run) reported;
}

/// Starts, stops, watches and mutes the local share on the session's room.
class VoiceScreenShare {
  VoiceScreenShare(
    this.host, {
    required BroadcastBridge broadcast,
    required this.desktopSources,
    required ShareAudioIsolation isolation,
  }) : control = ScreenShareControl(broadcast, isolation: isolation) {
    watch = ScreenShareWatch(
      participant: () => host.room()?.localParticipant,
      apply: _apply,
    );
  }

  final VoiceScreenShareHost host;
  final DesktopSources desktopSources;
  final ScreenShareControl control;
  late final ScreenShareWatch watch;

  Future<List<ScreenShareSource>> sources() async {
    final found = await host.reported(
      'list the screens and windows that can be shared',
      const <ScreenShareSource>[],
      desktopSources.list,
    );
    watch.noteSources(found);
    return found;
  }

  Future<ScreenShareOutcome> setEnabled(
      bool enabled, ShareRequest request) async {
    watch.stop();
    final outcome = await _apply(enabled, request);
    if (enabled) watch.watch(request, outcome);
    return outcome;
  }

  Future<ScreenShareOutcome> _apply(bool enabled, ShareRequest request) async {
    final ShareRequest(:quality, :sourceId, :includeAudio, :maxHeight) =
        request;
    final room = host.room();
    if (room == null) return ScreenShareOutcome.failed;
    if (!enabled) localShareCapturedSize.value = null;
    final outcome = await control.setEnabled(
      enabled,
      quality: quality,
      sourceId: sourceId,
      includeAudio: includeAudio,
      maxHeight: maxHeight,
      publish: (enabled, options, audio) => publishScreenShare(
        room.localParticipant,
        enabled: enabled,
        options: options,
        includeAudio: audio,
        quality: quality,
        maxHeight: maxHeight,
        measureSource: _measureAndKeep,
      ),
      isSharing: () => isSharingScreen(room.localParticipant),
      onSettled: (error) {
        if (error != null) host.noteError(error);
        host.refresh();
      },
    );
    host.refresh();
    return outcome;
  }

  Future<({int width, int height})?> _measureAndKeep(
    MediaStream stream,
  ) async {
    final size = await measureCapturedSize(stream);
    if (size != null) localShareCapturedSize.value = size;
    return size;
  }

  bool get hasAudio =>
      shareAudioPublication(host.room()?.localParticipant) != null;

  bool get audioMuted =>
      shareAudioPublication(host.room()?.localParticipant)?.muted ?? false;

  Future<bool> setAudioMuted(bool muted) => host.reported(
        'switch the shared audio',
        false,
        () => setShareAudioMuted(host.room()?.localParticipant, muted),
      );

  Widget view(
      String identity, ValueListenable<lk.AdaptiveStreamPixelDensity> density) {
    final room = host.room();
    if (room == null) return const SizedBox.shrink();
    return ScreenShareView(room: room, identity: identity, density: density);
  }
}
