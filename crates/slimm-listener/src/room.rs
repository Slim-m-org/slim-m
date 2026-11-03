// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The call, as the session sees it. [`RoomSource`] is the seam tests feed;
//! [`LiveKitRoom`] is the real one.
//!
//! The room is joined with `autoSubscribe` off. A track is subscribed only
//! when the session asks, and the session asks only for the MICROPHONE of
//! someone in its include set. Screen-share audio, camera, data and every
//! other track are never subscribed, so their audio never reaches this process.

use std::future::Future;

/// A published track, named by who owns it and its id.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TrackRef {
    pub identity: String,
    pub sid: String,
}

#[derive(Debug, PartialEq)]
pub enum RoomEvent {
    Published {
        track: TrackRef,
        microphone: bool,
    },
    Unpublished {
        track: TrackRef,
    },
    /// 16 kHz mono samples from a subscribed track.
    Audio {
        identity: String,
        samples: Vec<i16>,
    },
    Left {
        identity: String,
    },
    /// The connection to the room is gone.
    Closed,
}

pub trait RoomSource: Send {
    /// The next thing that happened, or `None` when the source is exhausted.
    fn next_event(&mut self) -> impl Future<Output = Option<RoomEvent>> + Send;

    /// Starts or stops receiving `track`'s audio.
    fn subscribe(&mut self, track: &TrackRef, on: bool);

    /// Leaves the room.
    fn leave(&mut self) -> impl Future<Output = ()> + Send;
}

#[cfg(feature = "livekit-room")]
pub use real::LiveKitRoom;

#[cfg(feature = "livekit-room")]
mod real {
    use std::collections::HashMap;

    use futures_util::StreamExt;
    use livekit::prelude::{RemoteTrack, RemoteTrackPublication, TrackSource};
    use livekit::webrtc::audio_stream::native::NativeAudioStream;
    use livekit::{Room, RoomEvent as Lk, RoomOptions};
    use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
    use tokio::task::JoinHandle;

    use super::{RoomEvent, RoomSource, TrackRef};

    const SAMPLE_RATE: i32 = 16_000;

    pub struct LiveKitRoom {
        room: Room,
        events: UnboundedReceiver<Lk>,
        audio: UnboundedReceiver<RoomEvent>,
        audio_tx: UnboundedSender<RoomEvent>,
        publications: HashMap<TrackRef, RemoteTrackPublication>,
        streams: HashMap<String, JoinHandle<()>>,
    }

    impl LiveKitRoom {
        /// Joins with `autoSubscribe` off.
        pub async fn connect(url: &str, token: &str) -> anyhow::Result<Self> {
            let mut options = RoomOptions::default();
            options.auto_subscribe = false;
            let (room, events) = Room::connect(url, token, options).await?;
            let (audio_tx, audio) = unbounded_channel();
            let mut joined = Self {
                room,
                events,
                audio,
                audio_tx,
                publications: HashMap::new(),
                streams: HashMap::new(),
            };
            joined.adopt_existing();
            Ok(joined)
        }

        /// Tracks published before this joined arrive as no event, so they are read once.
        fn adopt_existing(&mut self) {
            let mut found = Vec::new();
            for participant in self.room.remote_participants().values() {
                for publication in participant.track_publications().values() {
                    found.push(
                        self.remember(participant.identity().to_string(), publication.clone()),
                    );
                }
            }
            self.audio_tx_all(found);
        }

        fn audio_tx_all(&self, events: Vec<RoomEvent>) {
            for event in events {
                let _ = self.audio_tx.send(event);
            }
        }

        fn remember(&mut self, identity: String, publication: RemoteTrackPublication) -> RoomEvent {
            let track = TrackRef {
                identity,
                sid: publication.sid().to_string(),
            };
            let microphone = publication.source() == TrackSource::Microphone;
            self.publications.insert(track.clone(), publication);
            RoomEvent::Published { track, microphone }
        }

        fn translate(&mut self, event: Lk) -> Option<RoomEvent> {
            match event {
                Lk::TrackPublished {
                    publication,
                    participant,
                } => Some(self.remember(participant.identity().to_string(), publication)),
                Lk::TrackUnpublished {
                    publication,
                    participant,
                } => {
                    let track = TrackRef {
                        identity: participant.identity().to_string(),
                        sid: publication.sid().to_string(),
                    };
                    self.publications.remove(&track);
                    self.stop_stream(&track.sid);
                    Some(RoomEvent::Unpublished { track })
                }
                Lk::TrackSubscribed {
                    track: RemoteTrack::Audio(audio),
                    publication,
                    participant,
                } if publication.source() == TrackSource::Microphone => {
                    let identity = participant.identity().to_string();
                    let sid = publication.sid().to_string();
                    let sink = self.audio_tx.clone();
                    let mut stream = NativeAudioStream::new(audio.rtc_track(), SAMPLE_RATE, 1);
                    let task = tokio::spawn(async move {
                        while let Some(frame) = stream.next().await {
                            let event = RoomEvent::Audio {
                                identity: identity.clone(),
                                samples: frame.data.to_vec(),
                            };
                            if sink.send(event).is_err() {
                                return;
                            }
                        }
                    });
                    self.streams.insert(sid, task);
                    None
                }
                Lk::TrackUnsubscribed { publication, .. } => {
                    self.stop_stream(&publication.sid().to_string());
                    None
                }
                Lk::ParticipantDisconnected(participant) => Some(RoomEvent::Left {
                    identity: participant.identity().to_string(),
                }),
                Lk::Disconnected { .. } => Some(RoomEvent::Closed),
                _ => None,
            }
        }

        fn stop_stream(&mut self, sid: &str) {
            if let Some(task) = self.streams.remove(sid) {
                task.abort();
            }
        }
    }

    impl RoomSource for LiveKitRoom {
        async fn next_event(&mut self) -> Option<RoomEvent> {
            loop {
                tokio::select! {
                    biased;
                    ready = self.audio.recv() => return ready,
                    event = self.events.recv() => {
                        let event = event?;
                        if let Some(translated) = self.translate(event) {
                            return Some(translated);
                        }
                    }
                }
            }
        }

        fn subscribe(&mut self, track: &TrackRef, on: bool) {
            if let Some(publication) = self.publications.get(track) {
                publication.set_subscribed(on);
            }
            if !on {
                self.stop_stream(&track.sid);
            }
        }

        async fn leave(&mut self) {
            for (_, task) in self.streams.drain() {
                task.abort();
            }
            let _ = self.room.close().await;
        }
    }
}
