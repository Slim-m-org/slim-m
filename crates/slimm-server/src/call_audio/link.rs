// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server's WebSocket client to the listener (decision 0105).
//!
//! The server dials out, so the listener has no route into it. The link keeps
//! one connection open with backoff from 1 s to 30 s, and reports what happens
//! as [`LinkEvent`]s. Frames queued while it is down are dropped on reconnect:
//! a stale `stop` or `include` must never reach a listener that has no session.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use ws_client::tungstenite::Message;
use ws_client::tungstenite::client::IntoClientRequest;

use super::protocol::{self, DecodeError, FromListener, ToListener};
use crate::config::ListenerSettings;

const FIRST_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// The listener leaves every room after five quiet seconds, so it is pinged well inside that.
const KEEPALIVE: Duration = Duration::from_secs(2);
/// A link that has said nothing, not even a pong, for this long is half open.
const SILENCE_LIMIT: Duration = Duration::from_secs(6);
/// How long dialing the listener and its upgrade reply may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a connection may idle before it is pinged, and before it is given up on.
#[derive(Clone, Copy)]
struct Timing {
    keepalive: Duration,
    silence: Duration,
}

const TIMING: Timing = Timing {
    keepalive: KEEPALIVE,
    silence: SILENCE_LIMIT,
};

#[derive(Debug)]
pub enum LinkEvent {
    /// The listener sent `ready`.
    Ready {
        max_sessions: u32,
    },
    /// The connection is gone; every session must end.
    Disconnected,
    Message(FromListener),
}

#[derive(Clone)]
pub struct Link {
    out: mpsc::UnboundedSender<String>,
}

impl Link {
    pub fn send(&self, message: &ToListener) {
        let _ = self.out.send(protocol::encode(message));
    }
}

/// Starts the link task; the receiver yields what the listener does.
pub fn spawn(settings: &ListenerSettings) -> (Link, mpsc::UnboundedReceiver<LinkEvent>) {
    let (out, outbound) = mpsc::unbounded_channel();
    let (events, inbound) = mpsc::unbounded_channel();
    tokio::spawn(run(settings.clone(), outbound, events));
    (Link { out }, inbound)
}

/// `base` with the control path appended.
pub fn control_url(base: &str) -> String {
    listener_url(base, "/v1/control")
}

/// `base` with `route` appended, keeping any path prefix a proxy in front of the listener needs.
pub fn listener_url(base: &str, route: &str) -> String {
    format!("{}{route}", base.trim_end_matches('/'))
}

async fn run(
    settings: ListenerSettings,
    mut outbound: mpsc::UnboundedReceiver<String>,
    events: mpsc::UnboundedSender<LinkEvent>,
) {
    let mut backoff = FIRST_BACKOFF;
    loop {
        match connect(&settings, CONNECT_TIMEOUT).await {
            Ok(socket) => {
                while outbound.try_recv().is_ok() {}
                if converse(socket, &mut outbound, &events, &mut backoff, TIMING)
                    .await
                    .is_err()
                {
                    return;
                }
                if events.send(LinkEvent::Disconnected).is_err() {
                    return;
                }
            }
            Err(err) => tracing::debug!(%err, "call-audio listener is not reachable"),
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

type Socket = ws_client::WebSocketStream<ws_client::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(settings: &ListenerSettings, limit: Duration) -> anyhow::Result<Socket> {
    let mut request = control_url(&settings.url).into_client_request()?;
    request.headers_mut().insert(
        "authorization",
        format!("Bearer {}", settings.secret).parse()?,
    );
    let (socket, _) = tokio::time::timeout(limit, ws_client::connect_async(request)).await??;
    Ok(socket)
}

/// Runs one connection to its end. `Err` means the service is gone and the task should stop.
async fn converse(
    socket: Socket,
    outbound: &mut mpsc::UnboundedReceiver<String>,
    events: &mpsc::UnboundedSender<LinkEvent>,
    backoff: &mut Duration,
    timing: Timing,
) -> Result<(), ()> {
    let (mut sink, mut stream) = socket.split();
    let mut keepalive = tokio::time::interval(timing.keepalive);
    let mut last_heard = tokio::time::Instant::now();
    loop {
        tokio::select! {
            () = tokio::time::sleep_until(last_heard + timing.silence) => {
                tracing::warn!("the call-audio listener went silent; dropping the link");
                return Ok(());
            }
            _ = keepalive.tick() => {
                if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                    return Ok(());
                }
            }
            frame = stream.next() => {
                let Some(Ok(frame)) = frame else { return Ok(()) };
                last_heard = tokio::time::Instant::now();
                let Message::Text(text) = frame else {
                    if matches!(frame, Message::Close(_)) { return Ok(()) }
                    continue;
                };
                match protocol::decode(text.as_str()) {
                    Ok(FromListener::Ready { max_sessions, .. }) => {
                        *backoff = FIRST_BACKOFF;
                        events.send(LinkEvent::Ready { max_sessions }).map_err(|_| ())?;
                    }
                    Ok(message) => events.send(LinkEvent::Message(message)).map_err(|_| ())?,
                    Err(DecodeError::Newer(v)) => {
                        tracing::warn!(v, "call-audio listener speaks a newer protocol; closing");
                        let _ = sink.close().await;
                        return Ok(());
                    }
                    Err(DecodeError::Malformed(why)) => {
                        tracing::warn!(%why, "ignoring a malformed call-audio listener frame");
                    }
                }
            }
            queued = outbound.recv() => {
                let Some(text) = queued else { return Err(()) };
                if sink.send(Message::text(text)).await.is_err() {
                    return Ok(());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[test]
    fn the_control_path_is_appended_once() {
        assert_eq!(control_url("ws://l:9400"), "ws://l:9400/v1/control");
        assert_eq!(control_url("ws://l:9400/"), "ws://l:9400/v1/control");
    }

    async fn hold_open_without_reading() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let _socket = ws_client::accept_async(tcp).await.unwrap();
            tokio::time::sleep(Duration::from_secs(60)).await;
        });
        format!("ws://{addr}")
    }

    fn settings(url: String) -> ListenerSettings {
        ListenerSettings {
            url,
            secret: "x".repeat(32),
            livekit_url: None,
        }
    }

    #[tokio::test]
    async fn a_listener_that_stops_answering_is_dropped_within_the_silence_limit() {
        let url = hold_open_without_reading().await;
        let socket = connect(&settings(url), CONNECT_TIMEOUT).await.unwrap();
        let (_out, mut outbound) = mpsc::unbounded_channel();
        let (events, _inbound) = mpsc::unbounded_channel();
        let timing = Timing {
            keepalive: Duration::from_millis(50),
            silence: Duration::from_millis(300),
        };
        let ended = tokio::time::timeout(
            Duration::from_secs(5),
            converse(
                socket,
                &mut outbound,
                &events,
                &mut FIRST_BACKOFF.clone(),
                timing,
            ),
        )
        .await;
        assert!(matches!(ended, Ok(Ok(()))), "the link is given up on");
    }

    #[tokio::test]
    async fn a_listener_that_never_answers_the_upgrade_does_not_hang_the_dial() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (_tcp, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(60)).await;
        });
        let dialed = tokio::time::timeout(
            Duration::from_secs(5),
            connect(&settings(url), Duration::from_millis(200)),
        )
        .await;
        assert!(matches!(dialed, Ok(Err(_))), "the dial times out itself");
    }
}
