// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The line layout follows the mode: Off keeps today's layout, Compact flattens
//! span fields into one short line, Verbose adds the source file, line and thread.

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use tracing::{Event, Subscriber};
use tracing_subscriber::field::RecordFields;
use tracing_subscriber::fmt::format::{Compact, DefaultFields, Format, Full, Writer};
use tracing_subscriber::fmt::{FmtContext, FormatEvent, FormatFields};
use tracing_subscriber::registry::LookupSpan;

use super::LogMode;

pub struct ModeFormat {
    mode: Arc<AtomicU8>,
    off: Format<Full>,
    compact: Format<Compact>,
    verbose: Format<Full>,
}

impl ModeFormat {
    pub fn new(mode: Arc<AtomicU8>) -> Self {
        Self {
            mode,
            off: Format::default(),
            compact: Format::default().compact(),
            verbose: Format::default()
                .with_file(true)
                .with_line_number(true)
                .with_thread_ids(true),
        }
    }
}

impl<S, N> FormatEvent<S, N> for ModeFormat
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        writer: Writer<'_>,
        event: &Event<'_>,
    ) -> fmt::Result {
        match LogMode::from_u8(self.mode.load(Ordering::Relaxed)) {
            LogMode::Off => self.off.format_event(ctx, writer, event),
            LogMode::Compact => self.compact.format_event(ctx, writer, event),
            LogMode::Verbose => self.verbose.format_event(ctx, writer, event),
        }
    }
}

/// The files' field formatter. A type of its own, because span fields are formatted once per
/// formatter type and kept on the span, and stdout's copy carries colour codes.
#[derive(Default)]
pub struct PlainFields(DefaultFields);

impl<'writer> FormatFields<'writer> for PlainFields {
    fn format_fields<R: RecordFields>(&self, writer: Writer<'writer>, fields: R) -> fmt::Result {
        self.0.format_fields(writer, fields)
    }
}
