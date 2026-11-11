# 0112 - Pin silently, warn on change, spell the key as five words

Status: accepted
Date: 2026-11-11

## The ask

The owner reviewed the first-connect fingerprint screen and the changed-key screen and found both unreasonable: too many words, a colour strip that is hard to compare when two shades are close, a copy button nobody needs.
Trust on first use protects nothing on the first connection (see `crates/slimm-server/src/identity.rs`), and the 4-dot strip is about 10 bits, cheap to forge.

## What changed

- First connect pins the key silently.
  `ServerFingerprintStep` is removed.
  Every entry point still goes through `confirmServerIdentity`, and a relaunch is still re-checked by `ServerIdentityChangeGate`.
- A changed pin shows a blunt full-screen warning, "This isn't the server you joined before", with five words and two actions: "Go back" and "Trust the new server".
  No checkbox, no hex groups, no colour strip, no copy button.
- The five words are the first 55 bits of the SHA-256 of the 32-byte Ed25519 public key, 11 bits per word, from the BIP39 English list (public domain, 2048 words).
  They are derived on both sides: `fingerprint_words` in `identity.rs` and `fingerprintWordsOf` in `server_identity_fingerprint.dart`, which share one test vector.
- The server logs the same five words at startup, so an admin has them to read aloud.
- `color_strip` and `fingerprint_groups` stay on the `/version` wire as deprecated, so the response stays additive for older clients; no client reads them.
- Onboarding lists "Join the official Space" first.
