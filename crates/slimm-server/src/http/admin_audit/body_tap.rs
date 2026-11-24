// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Copies a request body as the handler reads it, so the audit log can inspect it afterwards.

use std::sync::{Arc, Mutex, PoisonError};

use axum::body::Body;
use futures_util::StreamExt;
use serde_json::Value;

#[derive(Default)]
struct Copy {
    bytes: Vec<u8>,
    overflowed: bool,
    failed: bool,
    ended: bool,
}

pub struct BodyTap {
    copy: Arc<Mutex<Copy>>,
}

/// What the handler's read of the body showed.
pub enum Seen {
    Json(Value),
    NotJson,
    /// Past the cap, failed, or left partly unread: the values are not known.
    Unread,
}

/// Returns a body that carries the original bytes unchanged, and the tap that copies up to `cap` of them.
pub fn tap(body: Body, cap: usize) -> (Body, BodyTap) {
    let copy = Arc::new(Mutex::new(Copy::default()));
    let on_chunk = Arc::clone(&copy);
    let on_end = Arc::clone(&copy);
    let seen = body.into_data_stream().inspect(move |chunk| {
        let mut copy = on_chunk.lock().unwrap_or_else(PoisonError::into_inner);
        match chunk {
            Ok(bytes) if !copy.overflowed && copy.bytes.len() + bytes.len() <= cap => {
                copy.bytes.extend_from_slice(bytes);
            }
            Ok(_) => {
                copy.overflowed = true;
                copy.bytes = Vec::new();
            }
            Err(_) => copy.failed = true,
        }
    });
    let ended = futures_util::stream::once(async move {
        on_end.lock().unwrap_or_else(PoisonError::into_inner).ended = true;
    })
    .filter_map(|()| async { None });
    (Body::from_stream(seen.chain(ended)), BodyTap { copy })
}

impl BodyTap {
    pub fn finish(self) -> Seen {
        let copy = self.copy.lock().unwrap_or_else(PoisonError::into_inner);
        let unread = !copy.ended && !copy.bytes.is_empty();
        if copy.overflowed || copy.failed || unread {
            return Seen::Unread;
        }
        serde_json::from_slice(&copy.bytes).map_or(Seen::NotJson, Seen::Json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{Bytes, to_bytes};

    fn chunks(parts: &[&[u8]]) -> Body {
        let owned: Vec<_> = parts
            .iter()
            .map(|part| Ok::<_, std::io::Error>(Bytes::copy_from_slice(part)))
            .collect();
        Body::from_stream(futures_util::stream::iter(owned))
    }

    #[tokio::test]
    async fn a_body_read_to_the_end_is_copied_whole() {
        let (body, tap) = tap(chunks(&[b"{\"a\":", b"1}"]), 64);
        assert_eq!(to_bytes(body, 1024).await.unwrap(), "{\"a\":1}");
        assert!(matches!(tap.finish(), Seen::Json(value) if value["a"] == 1));
    }

    #[tokio::test]
    async fn a_body_over_the_cap_reaches_the_reader_whole_and_is_unread() {
        let big = vec![b'x'; 100];
        let (body, tap) = tap(chunks(&[&big[..60], &big[60..]]), 64);
        assert_eq!(to_bytes(body, 1024).await.unwrap().len(), 100);
        assert!(matches!(tap.finish(), Seen::Unread));
    }

    #[tokio::test]
    async fn a_body_the_handler_never_read_is_not_inspected() {
        let (body, tap) = tap(chunks(&[b"{\"a\":1}"]), 64);
        drop(body);
        assert!(matches!(tap.finish(), Seen::NotJson));
    }
}
