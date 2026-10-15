<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0067 - Module install consent

Status: accepted, 2026-10-14.

## Decision

Before any new module power ships, installing a module shows a plain-language danger warning.
The warning names what each requested capability could do, for example "This module can send data from your server to api.example.com".
The admin must read it and explicitly accept before the install goes ahead.

Verified means listed in the official slim-addons registry, which is the Dock's official source.
Community sources are the unverified ones.
A verified module gets a "Verified" badge and a lighter warning, and it gets no extra powers.

Every capability stays its own approval switch, revocable after install (decision 0023).

An admin owns the risk for their space (owner, 2026-10-01).
The Dock warns, then lets them.
It does not block installs and does not nag on every action.

## What is built

A consent sheet opens from Install, and from Update when the new version asks for a capability the installed one did not.
An unverified module that asks for capabilities needs an "I understand what this module can do" tick before Install is enabled.
A verified module shows the same list with a lighter tone, and pressing Install is the acknowledgement.
An unverified module with no capabilities gets one line saying it runs code on the server, and no tick.
Update all leaves a module that asks for new access for its own page, and names it.

The warning sentence per capability is one table, `dockHostCapabilities` in `dock_host_access_card.dart`.
A capability that carries details, such as a host list, receives them in its sentence function.

## Coming next

A `network` capability allows outbound HTTP to the hosts named in the manifest, and a private or LAN address needs a second, separate confirmation.
A `schedule` capability runs the module on a timer with no person invoking it, and it posts as itself with a module badge.
Each is one entry in the table above.
