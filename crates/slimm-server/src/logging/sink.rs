// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hands formatted lines to one writer thread, so a slow disk never stalls a
//! request: a full queue drops the line and counts it instead.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::Duration;

use jiff::Timestamp;
use tracing_subscriber::fmt::MakeWriter;

use super::files::RollingFiles;

const QUEUE_LINES: usize = 8192;
const FLUSH_WAIT: Duration = Duration::from_secs(2);

enum Message {
    Line(Vec<u8>),
    Flush(SyncSender<()>),
}

#[derive(Clone)]
pub struct FileSink {
    queue: SyncSender<Message>,
    dropped: Arc<AtomicU64>,
}

impl FileSink {
    pub fn spawn(files: RollingFiles) -> io::Result<Self> {
        let (queue, lines) = mpsc::sync_channel(QUEUE_LINES);
        std::thread::Builder::new()
            .name("slimm-log-files".to_owned())
            .spawn(move || write_lines(files, &lines))?;
        Ok(Self {
            queue,
            dropped: Arc::default(),
        })
    }

    /// Waits until every line queued so far is on disk, or a couple of seconds pass.
    pub fn flush(&self) {
        let (ack, done) = mpsc::sync_channel(1);
        if self.queue.send(Message::Flush(ack)).is_ok() {
            let _ = done.recv_timeout(FLUSH_WAIT);
        }
    }

    /// Lines dropped because the queue was full, since the last call.
    pub fn take_dropped(&self) -> u64 {
        self.dropped.swap(0, Ordering::Relaxed)
    }
}

pub struct LineWriter<'a>(&'a FileSink);

impl io::Write for LineWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self.0.queue.try_send(Message::Line(buf.to_vec())) {
            Ok(()) => {}
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
                self.0.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for FileSink {
    type Writer = LineWriter<'a>;

    fn make_writer(&'a self) -> Self::Writer {
        LineWriter(self)
    }
}

/// Flushes whenever the queue runs dry, so a crash loses at most what was still queued.
fn write_lines(mut files: RollingFiles, lines: &Receiver<Message>) {
    let mut failing = false;
    while let Ok(first) = lines.recv() {
        let mut next = Some(first);
        while let Some(message) = next {
            let result = match message {
                Message::Line(line) => files.append(&line, Timestamp::now()),
                Message::Flush(ack) => {
                    let flushed = files.flush();
                    let _ = ack.send(());
                    flushed
                }
            };
            report(&mut failing, result);
            next = lines.try_recv().ok();
        }
        report(&mut failing, files.flush());
    }
}

/// Says so on stderr once per run of failures; logging the failure would only queue another line here.
fn report(failing: &mut bool, result: io::Result<()>) {
    match result {
        Ok(()) => *failing = false,
        Err(error) if !*failing => {
            *failing = true;
            eprintln!("server log files: {error}");
        }
        Err(_) => {}
    }
}
