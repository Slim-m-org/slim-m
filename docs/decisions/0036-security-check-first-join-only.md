# 0036 - The security check shows on first join only

Status: accepted
Date: 2026-09-28

## The ask

The 2026-09-16 signup audit flagged the hex SECURITY CHECK screen as possible friction on every invite join.
The owner decided on 2026-09-28: show it only the first time a device joins a given server (trust on first use).
A later join to the same server with the same key skips it.
A changed key for a known server must still stop the flow, as a warning.

## What the code does

`confirmServerIdentity` (`client/packages/app/lib/src/features/auth/widgets/server_identity_confirmation.dart`) is the one path every entry point uses: invite, manual address, official server and sign-in.
It pins the server's public key under `server_identity:<origin>` in the existing key store.

- No pin yet: `ServerFingerprintStep` ("Confirm this server").
  Confirming pins the key, cancelling pins nothing.
- Pin matches: no screen.
- Pin differs: `ServerIdentityChangedStep`, headed "This server's identity changed" in the danger colour with a warning callout.
  The button that re-pins the new key stays disabled until an explicit acknowledgement checkbox is ticked, so it cannot be tapped through.
- Unreachable: not blocked here.
- Reports no identity while nothing is pinned for the address: not blocked here.
- Reports no identity while a key is pinned: treated as a change, with the same warning.
  The real server always reports one, so a missing identity on a pinned address is not an old server.
  Continuing keeps the old pin.
- The compiled-in official server pins silently on first connect, and a later mismatch still stops.

This behaviour predates the decision; the audit's premise that the screen fires on every invite join was wrong for any device that had joined the server before.
The decision confirms it as intended and adds tests that pin it down on the invite path (`client/packages/app/test/features/auth/invite_join_tofu_test.dart`).

## Web and cleared storage

The pin lives in the platform key store, which is browser storage on web.
If that storage is cleared, the pin is gone and the device is treated as a first join, so the check shows again.
That is the safe direction: losing a pin can only cost an extra screen, never skip one.

## Relaunch

A relaunch of a signed-in session re-probes `/version` behind `ServerIdentityChangeGate`, and again each time sync reaches live.
A key that contradicts the pin shows the same acknowledgement step as sign-in; trusting it re-pins, cancelling ends the session.
An unreachable server, or nothing pinned yet, leaves the session alone.

## The check also gates the connection

Decided by the owner on 2026-11-10: signed-in requests wait for the `/version` identity check, one round trip at launch is accepted, and an unreachable `/version` fails open.
Before this, sync started as soon as the session was restored, so the first connect reached a server whose key had not been checked yet, and sync, push and presence kept running behind the step until Cancel.

- `SlimmApi` takes an optional `TrustGate`, and every call that carries the session awaits it: ordinary requests, byte fetches, downloads, streamed uploads, the diagnostics probes, the token refresh, and the video sources that attach the bearer themselves.
  `trust_gate_test.dart` lists each path, and a source gate fails a new file that reads the tokens without asking the gate.
- `apiProvider` hands each client `ServerIdentityGate.forClient()`.
  The first call waits for that server's identity answer, which is the `/version` read already shared with the client floor, so a matching pin adds no second read.
  After that, the call waits only while a mismatch stands.
- A server with nothing pinned, a `/version` that cannot be read, and a pinned server that answers with the pinned key all let the session through.
- Sync treats a standing mismatch as a stop state: it stops, does not reconnect on a timer, and starts again once the person trusts the key.
  Cancelling ends the session, so nothing restarts.
- The socket is minted by a gated ticket request and opened only after the gate, so none is opened while the step is up.

A reconnect after a drop still reconnects first and re-asks `/version` once it is live again, as before.
A key change seen then stops sync and holds every later call from that point.
Asking before each reconnect would cost a `/version` round trip per attempt and was not part of the decision.
A native video already playing keeps the header it was opened with; only a new open waits.
