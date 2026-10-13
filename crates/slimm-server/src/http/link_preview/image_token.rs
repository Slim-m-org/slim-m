// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Preview image tokens that carry their own upstream URL, signed.
//!
//! A token used to be a random id in the in-memory cache, so every restart
//! (and main deploys on every merge) voided every token a client still held,
//! and cards lost their pictures until the preview itself was refetched. A
//! signed token survives restarts and still lets the image endpoint proxy only
//! a URL this server put in a preview: it is not an open image proxy.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use sha2::Sha256;

/// Signature bytes kept in a token; 16 is ample against forgery here.
const SIGNATURE_BYTES: usize = 16;

fn signature(key: &[u8; 32], url: &str) -> [u8; SIGNATURE_BYTES] {
    let mut mac = <Hmac<Sha256>>::new_from_slice(key).expect("hmac takes any key length");
    mac.update(url.as_bytes());
    let full = mac.finalize().into_bytes();
    let mut out = [0; SIGNATURE_BYTES];
    out.copy_from_slice(&full[..SIGNATURE_BYTES]);
    out
}

/// The token for [url], the same every time for the same key.
pub(super) fn sign(key: &[u8; 32], url: &str) -> String {
    format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(url),
        URL_SAFE_NO_PAD.encode(signature(key, url))
    )
}

/// The URL [token] carries, when this key signed it.
pub(super) fn verify(key: &[u8; 32], token: &str) -> Option<String> {
    let (encoded, given) = token.split_once('.')?;
    let url = String::from_utf8(URL_SAFE_NO_PAD.decode(encoded).ok()?).ok()?;
    let given = URL_SAFE_NO_PAD.decode(given).ok()?;
    // Checked first: verify_truncated_left accepts any prefix, however short.
    if given.len() != SIGNATURE_BYTES {
        return None;
    }
    let mut mac = <Hmac<Sha256>>::new_from_slice(key).ok()?;
    mac.update(url.as_bytes());
    mac.verify_truncated_left(&given).ok()?;
    Some(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 32] = [7; 32];

    #[test]
    fn a_token_round_trips_and_is_stable() {
        let token = sign(&KEY, "https://cdn.example.com/a.png?x=1");
        assert_eq!(token, sign(&KEY, "https://cdn.example.com/a.png?x=1"));
        assert_eq!(
            verify(&KEY, &token).as_deref(),
            Some("https://cdn.example.com/a.png?x=1")
        );
    }

    #[test]
    fn a_forged_or_foreign_token_is_refused() {
        let token = sign(&KEY, "https://cdn.example.com/a.png");
        let (_, sig) = token.split_once('.').unwrap();
        let swapped = format!(
            "{}.{sig}",
            URL_SAFE_NO_PAD.encode("http://169.254.169.254/")
        );
        assert_eq!(verify(&KEY, &swapped), None);
        assert_eq!(verify(&[8; 32], &token), None);
        assert_eq!(verify(&KEY, "not-a-token"), None);
        let short = format!("{}.{}", token.split_once('.').unwrap().0, &sig[..4]);
        assert_eq!(verify(&KEY, &short), None);
    }
}
