# Screen inventory: onboarding, sign-in, and server identity

Part of [screen-inventory.md](screen-inventory.md).
Covers the join flow before an account exists, the sign-in/create-account screen, and the TOFU server-identity confirmation that both share.

Two harnesses exist.
"Surfaces harness" means `client/packages/app/test/ui_snapshot_test.dart`'s `_surfaces` map.
"Overlay harness" means `client/packages/app/test/snapshots/ui_overlay_snapshot_test.dart`'s `_overlays` map.
Neither harness drives a dialog open, submits a form, or forces a probe result in this flow, so almost everything below is uncaptured even though the routes themselves render.

## Onboarding root (`/join`)

- **onboarding-root** — the three-entry screen itself: "I have an invite," "Connect to a Space," "Join the official Space."
  - Reach: fresh launch with no server ever chosen, or `context.go(Routes.onboarding)` from sign-in's "Join a different Space."
  - Coverage: surfaces harness (`onboarding`), phone/desktop plus the `stepper-467/468` and `onboarding-899/900` breakpoint pairs. Only this bare state, no dialog ever opens.
  - Layout: `OnboardingShell` splits at 900px width (side brand panel vs stacked/centered); the stepper's own label-vs-pip switch sits at 420px of content width, independent of window width.

## Invite dialog (from "I have an invite")

- **invite-dialog-empty** — blank server + code fields, ToS checkbox unchecked, Continue disabled.
  - Reach: tap "I have an invite."
  - Coverage: none.
- **invite-dialog-address-error** — "That does not look like a server address."
  - Reach: submit with an unparseable/schemeless/hostless address.
  - Coverage: none.
- **invite-dialog-scheme-refused** — same field, `requireSecureScheme` message (public host, non-https, not LAN).
  - Reach: submit a plain-http address to a non-local host.
  - Coverage: none.
- **invite-dialog-busy** — Continue disabled, spinner, mid `checkInvite` call.
  - Coverage: none (transient).
- **invite-dialog-code-unusable** — "That code is not usable..." — deliberately identical for expired, spent, revoked, and never-issued codes (`InviteUnusable` carries no fields, by server design, so this is one state not four).
  - Coverage: none.
- **invite-dialog-unreachable** — "Could not reach that server."
  - Reach: `checkInvite` throws `TransportException`.
  - Coverage: none.
- **invite-dialog-server-refused** — "The server refused that. {message}" for any other `ApiException`.
  - Coverage: none.
- **invite-dialog-success** — pops `(server, code)`, falls straight into the TOFU section below before reaching sign-in.
  - Coverage: none.
- Layout: below 600px width renders as a bottom sheet, at or above as a centered dialog; content is identical either way.

## Manual server dialog (from "Connect to a Space")

- **manual-server-dialog-empty**, **manual-server-dialog-address-error**, **manual-server-dialog-scheme-refused**, **manual-server-dialog-success** — same four states and same messages as the invite dialog's address/scheme/success handling, minus the invite code field.
  - Coverage: none for any of the four.
  - Layout: same phone-sheet/desktop-dialog split.

## Official-server entry

- No dialog at all; the address is a compile-time constant, so only the TOFU states below are reachable from this entry, never the address/scheme errors.

## Server identity confirmation (TOFU) — shared by all three onboarding entries and sign-in submit

- **tofu-skip-server-too-old** — no screen shown, `confirmServerIdentity` returns true immediately.
  - Reach: `Version.identity == null` (pre-fingerprint server).
  - Coverage: none, and nothing to screenshot (this is an absence).
- **tofu-skip-unreachable** — no screen shown; a bare `catch (_)` in `confirmServerIdentity` treats a probe failure as safe.
  - Coverage: none. Indistinguishable client-side from the "too old" case above.
- **tofu-skip-key-matches** — no screen shown; pinned key equals fetched key.
  - Coverage: none.
- **tofu-first-connect-fingerprint** — full-screen `ServerFingerprintStep`: two rows of 4 hex groups plus a colour strip, "It matches - continue" / "Cancel."
  - Reach: nothing pinned yet for this address, and the server reports an identity. Pushed via `fadeThroughRoute`, outside `OnboardingShell`'s stepper.
  - Coverage: none.
  - Layout: `ConstrainedBox(maxWidth: 420)`, centered identically at every width — no responsive branch.
- **tofu-identity-changed** — `ServerIdentityChangedStep`: danger-toned "This server's identity changed," same fingerprint display, an acknowledgement checkbox gating a danger-styled "Trust the new identity" button, "Cancel" always available.
  - Reach: a pinned key exists for this address and differs from the freshly fetched one — a returning connection whose server key rotated.
  - Coverage: none.
  - Layout: no responsive branch, same as the fingerprint screen.
- **tofu-cancel-silent-abort** — cancelling either screen pops `false`; the calling flow (onboarding entry or sign-in submit) aborts with **no visible error or explanation**, landing back on the form that triggered it.
  - Coverage: none. Worth flagging as a UX gap in its own right, not only a state to capture.
- **tofu-confirm-continues** — confirming either screen pins the key and lets the flow proceed.
  - Coverage: none.
- Known gap, not a state to capture: a relaunch of an already-signed-in session never re-probes identity, so a key rotation is only ever caught on a fresh connect.

## Sign-in / create-account screen (`/sign-in`)

Two mutually exclusive modes:

- **sign-in-mode-welcome-back** — default form.
  - Reach: `/sign-in` with no pending invite. Surfaces harness (`sign-in`) renders exactly this, since `fixtureContainer` leaves `pendingInviteProvider` null.
- **sign-in-mode-create-account** — extra Display Name field, `OnboardingStep.identity` stepper visible.
  - Reach: arrived via a redeemed invite (`pendingInviteProvider != null` at `initState`), or manually toggled via "Create an account instead." Toggling clears any existing `_error`.
  - Coverage: none.

### Server-probe notices (debounced 600ms per edit, cleared to null immediately on edit — a visible "notices vanish" transient of its own)

- **probe-notice-none** — nothing rendered: probe pending, unreachable, a foreign non-slim-m 200, or an unparseable address all collapse to this one state by design.
  - Coverage: this is what the surfaces harness's `sign-in` entry actually renders — its fake HTTP client has no `/version` case, so `Version.fromJson` throws on the fallback `[]` response and the bare catch swallows it.
- **identity-chip-unknown** — no identity in `Version`, or no pin stored yet for this address.
- **identity-chip-confirmed** — pinned key matches probed key, green check.
- **identity-chip-mismatch** — pinned key differs, red glyph — purely informational here; the real block/confirm still happens in TOFU on submit.
- **safety-notice-hidden** — `SafetyTools.present`, renders nothing.
- **safety-notice-unknown** — server predates 0.17.0 (`capabilities == null`), "too old to say."
- **safety-notice-missing-both** — neither report nor block offered.
- **safety-notice-missing-report** — report absent, block present.
- **safety-notice-missing-block** — block absent, report present.
- **invite-required-notice** — shown only while `_creatingAccount && probed.inviteRequired == true`; null/unknown on servers before 0.14.2.
- **push-disabled-notice** — shown only when `probed.pushEnabled == false`.
- **probe-notices-stacked** — an old, invite-only, push-disabled, safety-incomplete server creating an account stacks the chip plus all three notices at once. Worth capturing deliberately since nothing else exercises the combination.
  - Coverage: none of the above ten notice states.

### Submit-path states (`_submit`)

- **submit-address-error**, **submit-scheme-refused** — same messages as the dialogs above, on the `_ErrorField.server` slot.
- **submit-identity-confirm-triggered** — falls into the TOFU section; cancelling resets `_busy` with no error shown (same silent-abort gap as onboarding).
- **submit-busy** — spinner in the submit button, every other control disabled.
- **submit-wrong-credentials** — `UnauthorizedException` → `_ErrorField.password`, "Wrong username or password."
- **submit-username-taken** — `ConflictException`, register only → `_ErrorField.username`.
- **submit-bad-request** — `BadRequestException` → `_ErrorField.form`, server's own message.
- **submit-rate-limited** — `RateLimitedException` → "Too many attempts... wait a moment."
- **submit-server-unavailable** — `UnavailableException` → `_ErrorField.form`.
- **submit-unreachable** — `TransportException` → `_ErrorField.server`, "This Space didn't answer... Nothing was sent."
- **submit-generic-refusal** — any other `ApiException` → "The server refused that. {message}."
- **submit-success-register** — account created, invite (if any) redeemed together in one call.
- **submit-success-login-pending-invite-silently-fails** — login succeeds, a best-effort `redeemInvite` follow-up throws and is **swallowed silently**; the session completes with the invite's role never granted and nothing telling the user. Worth capturing as a real, easy-to-miss reachable state, not just a code path.
- **submit-join-different-space** — "Join a different Space" link, `context.go(Routes.onboarding)`.
  - Coverage: none of the fourteen submit-path states above are exercised by either harness.

## Router-level session states

- **router-fresh-no-server** — `signedOutHome()` → `/join`.
- **router-signed-out-server-remembered** — `signedOutHome()` → `/sign-in`, prefilled address. This is also what a revoked session lands on today; CLAUDE.md's older "drops to bare onboarding, loses the address" note is stale against the current `router.dart` and should be treated as fixed rather than open, pending one live confirmation.
- **router-mid-join-flow-untouched** — navigating between `/join` and `/sign-in` while signed out does not get redirected mid-walk.
- **router-already-signed-in-redirect** — landing on `/join` or `/sign-in` while signed in bounces straight to `/channels`.
  - Coverage: none of the four are screenshot targets in their own right (they are redirects), but the destination screens are covered elsewhere in this inventory.
