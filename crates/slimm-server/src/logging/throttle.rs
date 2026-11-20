// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! In Verbose, caps how many debug and trace lines one call site may write per
//! second, so a hot loop cannot bury everything else. Info and above always
//! pass, and the other modes are never capped: Compact's one per-request line
//! comes from a single call site.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use tracing::callsite::Identifier;
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::layer::{Context, Layer};

use super::LogMode;

const WINDOW: Duration = Duration::from_secs(1);

pub struct Throttle {
    per_window: u32,
    mode: Arc<AtomicU8>,
    windows: Mutex<HashMap<Identifier, Window>>,
    dropped: Arc<AtomicU64>,
}

struct Window {
    started: Instant,
    seen: u32,
}

impl Throttle {
    pub fn new(per_second: u32, mode: Arc<AtomicU8>, dropped: Arc<AtomicU64>) -> Self {
        Self {
            per_window: per_second,
            mode,
            windows: Mutex::default(),
            dropped,
        }
    }

    fn admit(&self, callsite: Identifier, now: Instant) -> bool {
        let mut windows = self.windows.lock().unwrap_or_else(PoisonError::into_inner);
        let window = windows.entry(callsite).or_insert(Window {
            started: now,
            seen: 0,
        });
        if now.duration_since(window.started) >= WINDOW {
            window.started = now;
            window.seen = 0;
        }
        window.seen += 1;
        let admitted = window.seen <= self.per_window;
        if !admitted {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
        admitted
    }
}

impl<S: Subscriber> Layer<S> for Throttle {
    fn event_enabled(&self, event: &Event<'_>, _ctx: Context<'_, S>) -> bool {
        let metadata = event.metadata();
        if !matches!(*metadata.level(), Level::DEBUG | Level::TRACE)
            || LogMode::from_u8(self.mode.load(Ordering::Relaxed)) != LogMode::Verbose
        {
            return true;
        }
        self.admit(metadata.callsite(), Instant::now())
    }
}
