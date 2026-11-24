<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0141 - Where the web client keeps its sign-in (A)

Status: proposed, waiting for the owner
Date: 2026-11-24
Extends: 0042 (local database key)

## The question

The web client is served at `/app` by the live deployment, so it is a distribution target, not only a test harness.
Its sign-in is stored through flutter_secure_storage's browser backend.
That backend encrypts the 30-day refresh token with AES-GCM under a key that sits in `localStorage` beside it, so any script running on the page's origin can read both.
Is that acceptable, and if not, what replaces it?

## What is true today

- The page is served with a CSP of `script-src 'self' 'wasm-unsafe-eval'`, which makes an injected script harder but not impossible (a compromised dependency, a future page that loosens the policy).
- A stolen refresh token is a full session for 30 days, because the token slides on every rotation.
- A stolen access token is only 15 minutes.
- A plain-http LAN server gets no persisted session at all, because the backend refuses outside a secure context.

## Options

1. **Keep the refresh token in an HttpOnly, Secure, SameSite=Strict cookie scoped to `/auth/refresh`, and the access token in memory only.**
   Script on the page can no longer read the long-lived credential.
   Needs server work: `/auth/login` and `/auth/refresh` set and read the cookie for browser callers, `/auth/logout` clears it, and the web client stops writing the pair to storage.
   Native clients keep the JSON body, so the change is additive on the wire.
   A reload costs one refresh call before the first request.
2. **Keep the pair in `sessionStorage` or memory for the web build.**
   Smaller change, but the member signs in again whenever the tab or browser closes, which is a product cost every web user pays.
3. **Keep today's storage and say so.**
   Honest, and the cheapest, but one script injection yields a durable session.

## Recommendation

Option 1, as its own card with server, client and e2e work.
Until the owner picks, the web build stays on today's storage and `docs/internals.md` says plainly what that protects against (nothing that runs on the origin).

## What this record does not decide

Cookie lifetime, whether a cookie session also needs a CSRF token on `/auth/refresh`, and whether an admin session on the web should get a shorter refresh window than a member's.
