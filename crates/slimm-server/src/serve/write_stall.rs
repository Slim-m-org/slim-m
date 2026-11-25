// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A socket wrapper that gives up on a peer that has stopped reading.
//!
//! A write that cannot make progress for the whole timeout fails, which ends the
//! connection and frees whatever it held open: a download's file handle, a
//! socket's slot. Reads and idle connections are untouched, so a quiet
//! WebSocket or a keep-alive connection between requests is never cut by it.

use std::io::{self, IoSlice};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::time::{Sleep, sleep};

pub(super) struct WriteStall<T> {
    inner: T,
    timeout: Duration,
    deadline: Option<Pin<Box<Sleep>>>,
}

impl<T> WriteStall<T> {
    pub(super) fn new(inner: T, timeout: Duration) -> Self {
        Self {
            inner,
            timeout,
            deadline: None,
        }
    }

    fn settle<R>(
        &mut self,
        cx: &mut Context<'_>,
        polled: Poll<io::Result<R>>,
    ) -> Poll<io::Result<R>> {
        if polled.is_ready() {
            self.deadline = None;
            return polled;
        }
        let timeout = self.timeout;
        let deadline = self
            .deadline
            .get_or_insert_with(|| Box::pin(sleep(timeout)));
        if deadline.as_mut().poll(cx).is_ready() {
            self.deadline = None;
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the peer stopped reading",
            )));
        }
        polled
    }
}

impl<T: AsyncRead + Unpin> AsyncRead for WriteStall<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for WriteStall<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let polled = Pin::new(&mut self.inner).poll_write(cx, buf);
        self.settle(cx, polled)
    }

    fn poll_write_vectored(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        let polled = Pin::new(&mut self.inner).poll_write_vectored(cx, bufs);
        self.settle(cx, polled)
    }

    fn is_write_vectored(&self) -> bool {
        self.inner.is_write_vectored()
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let polled = Pin::new(&mut self.inner).poll_flush(cx);
        self.settle(cx, polled)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let polled = Pin::new(&mut self.inner).poll_shutdown(cx);
        self.settle(cx, polled)
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt, duplex};
    use tokio::time::Instant;

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_write_the_peer_never_drains_times_out() {
        let (writer, _unread) = duplex(8);
        let mut writer = WriteStall::new(writer, Duration::from_secs(60));
        let started = Instant::now();
        let error = writer.write_all(&[0u8; 64]).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() >= Duration::from_secs(60));
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_reader_that_keeps_draining_is_not_cut() {
        let (writer, mut reader) = duplex(8);
        let mut writer = WriteStall::new(writer, Duration::from_secs(60));
        let drain = tokio::spawn(async move {
            let mut got = 0;
            let mut buf = [0u8; 8];
            while got < 64 {
                tokio::time::sleep(Duration::from_secs(40)).await;
                got += reader.read(&mut buf).await.unwrap();
            }
        });
        writer.write_all(&[0u8; 64]).await.unwrap();
        drain.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn an_idle_connection_is_never_cut() {
        let (writer, mut reader) = duplex(8);
        let _writer = WriteStall::new(writer, Duration::from_secs(60));
        tokio::time::sleep(Duration::from_secs(3600)).await;
        let mut buf = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(1), reader.read(&mut buf)).await;
        assert!(read.is_err(), "nothing was written, so nothing ends");
    }
}
