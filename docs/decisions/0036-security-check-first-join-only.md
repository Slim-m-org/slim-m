# 0036 - The security check shows on first join only

Status: accepted
Date: 2026-09-28

## The ask

The 2026-09-16 signup audit flagged the hex SECURITY CHECK screen as possible friction on every invite join.
The owner decided on 2026-09-28: show it only the first time a device joins a given server (trust on first use).
A later join to the same server with the same key skips it.
A changed key for a known server must still stop the flow, as a warning.

## What the code does

`confirmServerIdentity` (`client/packages/app/lib/src/widgets/server_identity_confirmation.dart`) is the one path every entry point uses: invite, manual address, official server and sign-in.
It pins the server's public key under `server_identity:<origin>` in the existing key store.

- No pin yet: `ServerFingerprintStep` ("Confirm this server").
  Confirming pins the key, cancelling pins nothing.
- Pin matches: no screen.
- Pin differs: `ServerIdentityChangedStep`, headed "This server's identity changed" in the danger colour with a warning callout.
  The button that re-pins the new key stays disabled until an explicit acknowledgement checkbox is ticked, so it cannot be tapped through.
- Server too old to report an identity, or unreachable: not blocked here, unless a key is already pinned for that address.
  A pinned server that answers with no identity is treated as a change (issue 1982).
  The real server always sends one, so leaving it out is the one way to skip the warning.
- The compiled-in official server pins silently on first connect, and a later mismatch still stops.

This behaviour predates the decision; the audit's premise that the screen fires on every invite join was wrong for any device that had joined the server before.
The decision confirms it as intended and adds tests that pin it down on the invite path (`client/packages/app/test/invite_join_tofu_test.dart`).

## Web and cleared storage

The pin lives in the platform key store, which is browser storage on web.
If that storage is cleared, the pin is gone and the device is treated as a first join, so the check shows again.
That is the safe direction: losing a pin can only cost an extra screen, never skip one.

## Relaunch

A relaunch of a signed-in session re-probes `/version` behind `ServerIdentityChangeGate`, and again on every reconnect.
A key that contradicts the pin shows the same acknowledgement step as sign-in; trusting it re-pins, cancelling ends the session.
An unreachable server, or nothing pinned yet, leaves the session alone.
