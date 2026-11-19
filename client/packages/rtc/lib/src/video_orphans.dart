// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Camera and screen tracks livekit left capturing with no publication.
///
/// A full restart clears the local publications and republishes them one at a
/// time, and one that throws ends the rest, so a camera can keep capturing
/// with nothing published: the light stays on while the call shows it off,
/// and the room's own cleanup at a leave stops only published tracks.
library;

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogTag;

const _watched = {
  lk.TrackSource.camera,
  lk.TrackSource.screenShareVideo,
  lk.TrackSource.screenShareAudio,
};

/// Remembers every camera and screen track this call published, so one left
/// with no publication can still be stopped.
class VideoOrphans {
  final _published = <lk.LocalTrack>{};

  void onRoomEvent(lk.RoomEvent event) {
    if (event is! lk.LocalTrackPublishedEvent) return;
    final track = event.publication.track;
    if (track != null && _watched.contains(event.publication.source)) {
      _published.add(track);
    }
  }

  /// Stops each remembered track [local] no longer publishes; returns the
  /// sources of those that were capturing.
  Future<Set<lk.TrackSource>> stopUnpublished(lk.LocalParticipant local) {
    final live = <lk.Track?>{
      for (final p in local.videoTrackPublications) p.track,
      for (final p in local.audioTrackPublications) p.track,
    };
    final orphans = _published.where((t) => !live.contains(t)).toList();
    _published.removeAll(orphans);
    return stopCapturing(orphans);
  }

  /// Forgets every remembered track and hands them to the call that is ending,
  /// so its teardown, however late, never reaches a newer call's tracks.
  List<lk.LocalTrack> takeAll() {
    final all = _published.toList();
    _published.clear();
    return all;
  }
}

/// Stops each of [tracks] still capturing; returns their sources.
Future<Set<lk.TrackSource>> stopCapturing(List<lk.LocalTrack> tracks) async {
  final stopped = <lk.TrackSource>{};
  for (final track in tracks) {
    if (!track.isActive) continue;
    stopped.add(track.source);
    await track.stop();
  }
  if (stopped.isNotEmpty) {
    AppLog.at(LogLevel.warning, LogTag.voice,
        'Stopped ${stopped.map((s) => s.name).join(', ')} left capturing with no publication');
  }
  return stopped;
}
