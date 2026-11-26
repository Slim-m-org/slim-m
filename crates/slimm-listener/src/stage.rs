// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Plays [`Speech`] into a LiveKit room as one short-lived participant: join
//! with the token the server minted, publish a microphone track, send the
//! samples in real time, leave.

use crate::speak::Speech;

/// What libwebrtc's audio path runs at; Piper voices are 16 or 22.05 kHz.
pub const STAGE_RATE: u32 = 48_000;

/// `samples` at `from` Hz as `STAGE_RATE`, by linear interpolation, which is plenty for speech.
pub fn resample(speech: &Speech) -> Vec<i16> {
    let (from, to) = (u64::from(speech.sample_rate.max(1)), u64::from(STAGE_RATE));
    let out_len = speech.samples.len() as u64 * to / from;
    (0..out_len)
        .map(|n| {
            let pos = n * from;
            let (i, frac) = ((pos / to) as usize, (pos % to) as i64);
            let a = i64::from(speech.samples[i]);
            let b = i64::from(*speech.samples.get(i + 1).unwrap_or(&speech.samples[i]));
            (a + (b - a) * frac / to as i64) as i16
        })
        .collect()
}

#[cfg(feature = "livekit-room")]
pub use real::LiveKitStage;

#[cfg(feature = "livekit-room")]
mod real {
    use std::time::Duration;

    use anyhow::Context;
    use livekit::options::TrackPublishOptions;
    use livekit::prelude::*;
    use livekit::webrtc::audio_frame::AudioFrame;
    use livekit::webrtc::audio_source::native::NativeAudioSource;
    use livekit::webrtc::audio_source::{AudioSourceOptions, RtcAudioSource};

    use super::{STAGE_RATE, resample};
    use crate::speak::{Boxed, Speech, Stage};

    /// Silence after the last word, so the receiver's jitter buffer plays it out before the track ends.
    const TAIL: Duration = Duration::from_millis(400);

    pub struct LiveKitStage;

    impl Stage for LiveKitStage {
        fn perform<'a>(
            &'a self,
            url: &'a str,
            token: &'a str,
            speech: &'a Speech,
        ) -> Boxed<'a, ()> {
            Box::pin(async move {
                let (room, _events) = Room::connect(url, token, RoomOptions::default())
                    .await
                    .context("joining the room")?;
                let source =
                    NativeAudioSource::new(AudioSourceOptions::default(), STAGE_RATE, 1, 200);
                let track = LocalAudioTrack::create_audio_track(
                    "tts",
                    RtcAudioSource::Native(source.clone()),
                );
                let options = TrackPublishOptions {
                    source: TrackSource::Microphone,
                    ..TrackPublishOptions::default()
                };
                room.local_participant()
                    .publish_track(LocalTrack::Audio(track), options)
                    .await
                    .context("publishing the track")?;
                let mut samples = resample(speech);
                samples.extend(std::iter::repeat_n(
                    0,
                    (STAGE_RATE as u128 * TAIL.as_millis() / 1000) as usize,
                ));
                for chunk in samples.chunks(STAGE_RATE as usize / 100) {
                    let frame = AudioFrame {
                        data: chunk.into(),
                        sample_rate: STAGE_RATE,
                        num_channels: 1,
                        samples_per_channel: chunk.len() as u32,
                    };
                    source
                        .capture_frame(&frame)
                        .await
                        .context("sending audio")?;
                }
                room.close().await.context("leaving the room")?;
                Ok(())
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_ramp_is_stretched_to_the_stage_rate_in_proportion() {
        let speech = Speech {
            samples: vec![0, 100, 200, 300],
            sample_rate: 16_000,
        };
        let out = resample(&speech);
        assert_eq!(out.len(), 12);
        assert_eq!(out[0], 0);
        assert!(out.windows(2).all(|w| w[0] <= w[1]), "stays a ramp");
        assert!(out[11] >= 200);
    }

    #[test]
    fn nothing_in_is_nothing_out() {
        let speech = Speech {
            samples: vec![],
            sample_rate: 22_050,
        };
        assert!(resample(&speech).is_empty());
    }
}
