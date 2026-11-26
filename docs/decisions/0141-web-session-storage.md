<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0141 - Where the web client keeps its sign-in (A)

Status: accepted, option 1 (owner, 2026-11-25); implemented
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

## Decision

The owner chose option 1 on 2026-11-25.
The web client's refresh token moves to an HttpOnly, Secure, SameSite=Strict cookie scoped to `/auth/refresh`, and the access token is kept in memory only.
Desktop and phone clients keep their current storage.
The server and client work is tracked on Planka ("Web sign-in: refresh token in an HttpOnly cookie").

### Implementation

How a web client identifies itself:
It sends the request header `x-slimm-web-session: cookie` on every call, and the server acts on it only for the calls that mint, rotate or end a session.
An explicit header, not user-agent sniffing, so a native client or a script never gets a cookie by accident and the non-web wire stays byte-identical.

What the server does for a client that sent it:
`/auth/register`, `/auth/login`, `/auth/totp/verify` and `/auth/refresh` set the refresh token as `__Secure-slimm_rt_<user_id>=<token>; HttpOnly; Secure; SameSite=Strict; Path=/auth/refresh; Max-Age=<remaining lifetime>` and leave `refresh_token` out of the JSON body.
`/auth/refresh` takes the body token when one is sent (a pair stored before the cookie existed spends it once and the reply moves it into the cookie), and otherwise reads the cookie of the account named in `x-slimm-account`.
Every rotation sets the cookie again.
`/auth/logout`, removing the caller's own device, deleting the account, and a refused refresh (spent, revoked, expired or missing) all send the same cookie with `Max-Age=0`, so a dead cookie stops being presented.
The old `refresh_token` field of the response schemas is no longer required; `schema/oasdiff-err-ignore.txt` names the four affected responses because an older client never sends the header and so always still gets it.

CSRF:
`SameSite=Strict` keeps the cookie off cross-site requests, and a cookie refresh without the custom header is refused, because a cross-site form post cannot add one and the CORS policy never allows credentials.
The cookie itself is scoped to `/auth/refresh`, so no other route ever sees it.

Several accounts in one browser:
The cookie name carries the account id, and a refresh names the account it wants in `x-slimm-account`.
Two accounts therefore coexist side by side in one jar, and a tab that signs in as someone else cannot silently swap another tab's session: that tab's refresh still asks for its own account.
The account switcher's servers are different origins and so different cookie jars anyway.

What the web client keeps:
The access token lives in memory only.
The key store holds `{"user_id": ...}` and nothing else under the session handle: the public account id is the one marker that a cookie is worth presenting after a reload, and it is no credential.
A reload resumes with an empty access token, the first call answers 401, and the shared refresh path posts to `/auth/refresh` and gets a fresh access token from the cookie.
A pair an older build stored is deleted on the first load and its refresh token spent once into the cookie, so nobody is signed out by the update.
Tabs still take the shared refresh lock, because two tabs presenting one cookie value at once would read as reuse.

Where the cookie cannot work the tab keeps nothing at all, and a reload signs in again:
a plain-http address that is not loopback (the browser refuses a Secure cookie there, which is today's no-persisted-session behaviour), and a server on another origin than the page (a Strict cookie never travels cross-site).
Desktop and phones are unchanged.
