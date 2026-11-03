// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Energy-based utterance detection on one person's 16 kHz mono stream.
//!
//! 20 ms frames. The speech threshold follows the stream's own noise floor, so
//! a noisy room and a quiet one both work. 600 ms of silence ends an utterance;
//! one shorter than 400 ms is dropped; one longer than 15 s is cut and the rest
//! becomes the next utterance. PCM is held in memory only.

use std::collections::VecDeque;

pub const SAMPLE_RATE: usize = 16_000;
const FRAME_SAMPLES: usize = SAMPLE_RATE / 50;
const FRAME_MS: i64 = 20;
const END_SILENCE_MS: i64 = 600;
const MIN_UTTERANCE_MS: i64 = 400;
pub const MAX_UTTERANCE_MS: i64 = 15_000;
/// Audio kept from before the first loud frame, so a word is not clipped.
const PRE_ROLL_FRAMES: usize = 5;
/// Speech must be this many times the noise floor.
const THRESHOLD_RATIO: f32 = 3.0;
/// The quietest threshold, so digital silence does not make every click speech.
const MIN_THRESHOLD: f32 = 150.0;
const MIN_FLOOR: f32 = 20.0;
/// How much of the floor survives a frame louder than it: a time constant of about 40 s.
const FLOOR_RISE_KEEP: f32 = 0.9995;

/// Speech between two silences.
#[derive(Debug, Clone, PartialEq)]
pub struct Utterance {
    pub start_ms: i64,
    pub end_ms: i64,
    pub pcm: Vec<i16>,
}

impl Utterance {
    pub fn duration_ms(&self) -> i64 {
        self.end_ms - self.start_ms
    }
}

pub struct Endpointer {
    /// When the first sample arrived, in milliseconds since the session started.
    origin_ms: i64,
    pending: Vec<i16>,
    frames_seen: i64,
    floor: f32,
    pre_roll: VecDeque<Vec<i16>>,
    active: Option<Active>,
}

struct Active {
    start_frame: i64,
    /// Pre-roll frames, which are not speech.
    lead: i64,
    pcm: Vec<i16>,
    quiet_frames: i64,
}

impl Endpointer {
    pub fn new(origin_ms: i64) -> Self {
        Self {
            origin_ms,
            pending: Vec::new(),
            frames_seen: 0,
            floor: 100.0,
            pre_roll: VecDeque::new(),
            active: None,
        }
    }

    /// Feeds samples and returns the utterances that ended in them.
    pub fn push(&mut self, samples: &[i16]) -> Vec<Utterance> {
        self.pending.extend_from_slice(samples);
        let mut done = Vec::new();
        while self.pending.len() >= FRAME_SAMPLES {
            let frame: Vec<i16> = self.pending.drain(..FRAME_SAMPLES).collect();
            if let Some(utterance) = self.frame(frame) {
                done.push(utterance);
            }
        }
        done
    }

    /// Ends whatever is in progress, for a speaker who left or stopped.
    pub fn finish(&mut self) -> Option<Utterance> {
        let active = self.active.take()?;
        self.close(active)
    }

    fn threshold(&self) -> f32 {
        (self.floor * THRESHOLD_RATIO).max(MIN_THRESHOLD)
    }

    fn frame(&mut self, frame: Vec<i16>) -> Option<Utterance> {
        let level = rms(&frame);
        let loud = level > self.threshold();
        let index = self.frames_seen;
        self.frames_seen += 1;
        self.follow_floor(level);
        let Some(mut active) = self.active.take() else {
            if loud {
                self.begin(index, frame);
            } else {
                self.pre_roll.push_back(frame);
                if self.pre_roll.len() > PRE_ROLL_FRAMES {
                    self.pre_roll.pop_front();
                }
            }
            return None;
        };
        active.pcm.extend_from_slice(&frame);
        active.quiet_frames = if loud { 0 } else { active.quiet_frames + 1 };
        let length_ms = (index + 1 - active.start_frame) * FRAME_MS;
        if active.quiet_frames * FRAME_MS >= END_SILENCE_MS || length_ms >= MAX_UTTERANCE_MS {
            return self.close(active);
        }
        self.active = Some(active);
        None
    }

    /// Falls to quiet fast and rises slowly, so a room that gets noisier is
    /// learned within seconds and a long stretch of speech barely moves it.
    fn follow_floor(&mut self, level: f32) {
        let keep = if level < self.floor {
            0.9
        } else {
            FLOOR_RISE_KEEP
        };
        self.floor = (self.floor * keep + level * (1.0 - keep)).max(MIN_FLOOR);
    }

    fn begin(&mut self, index: i64, first: Vec<i16>) {
        let lead = self.pre_roll.len() as i64;
        let mut pcm: Vec<i16> = self.pre_roll.drain(..).flatten().collect();
        pcm.extend_from_slice(&first);
        self.active = Some(Active {
            start_frame: index - lead,
            lead,
            pcm,
            quiet_frames: 0,
        });
    }

    fn close(&mut self, active: Active) -> Option<Utterance> {
        let frames = (active.pcm.len() / FRAME_SAMPLES) as i64;
        let spoken_ms = (frames - active.quiet_frames - active.lead) * FRAME_MS;
        if spoken_ms < MIN_UTTERANCE_MS {
            return None;
        }
        let start_ms = self.origin_ms + active.start_frame * FRAME_MS;
        Some(Utterance {
            start_ms,
            end_ms: start_ms + frames * FRAME_MS,
            pcm: active.pcm,
        })
    }
}

fn rms(frame: &[i16]) -> f32 {
    let sum: f64 = frame.iter().map(|s| f64::from(*s) * f64::from(*s)).sum();
    (sum / frame.len().max(1) as f64).sqrt() as f32
}

#[cfg(test)]
mod tests;
