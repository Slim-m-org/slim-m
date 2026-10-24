// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:livekit_client/livekit_client.dart' as lk;

/// Whose platform audio a room event may have replaced: a person's identity,
/// [everyone] after a reconnect, or null when the event touches no audio.
const String everyone = '*';

String? audioReplacedBy(lk.RoomEvent event) => switch (event) {
      lk.TrackSubscribedEvent(:final participant) => participant.identity,
      lk.TrackUnsubscribedEvent(:final participant) => participant.identity,
      lk.TrackPublishedEvent(:final participant) => participant.identity,
      lk.TrackMutedEvent(:final participant) => participant.identity,
      lk.TrackUnmutedEvent(:final participant) => participant.identity,
      lk.ParticipantConnectedEvent(:final participant) => participant.identity,
      lk.ParticipantDisconnectedEvent(:final participant) =>
        participant.identity,
      lk.RoomReconnectedEvent() || lk.RoomResumingEvent() => everyone,
      _ => null,
    };
