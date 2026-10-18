# 0048 - TOTP two-factor authentication

Status: accepted, 2026-09-30.

## Why now

`docs/research/security.md` recorded "TOTP is optional 2FA, recommended for admins; passkeys later" as a verdict and nothing was ever built.
That gap matters more here than in most products because decision 0001 rules out email recovery entirely: recovery is admin-issued one-time reset codes.
A password is therefore the only factor for everyone, including an administrator, and on a self-hosted deployment an administrator account is the whole deployment.
There is not even an email account acting as an accidental second factor.

## What is built

TOTP, RFC 6238, HMAC-SHA1, six digits, a thirty-second step.
Those are the otpauth defaults every authenticator app already speaks, and the provisioning URI states none of them for that reason: several popular apps mis-handle the parameters when they are named explicitly.
SHA-256 and eight digits are both in the spec and buy nothing here - the secret is 160 bits either way, and what bounds guessing a code is the failure budget below, not the digest.

The RFC arithmetic is `totp-rs`, not hand-rolled.
It is held at the 5.x line, and that is load-bearing: 6.0 moved to `hmac` 0.13 and `crypto-common` 0.2.x, which cannot co-exist with the `crypto-common` 0.2.0-rc.4 that this tree's exact-pinned `crypto_box` pre-release requires.
5.x rides the `hmac`/`sha1`/`sha2` versions already present and adds only `base32` and `constant_time_eq`.

TOTP is the right shape for a self-hosted product: no SMS, no third-party service, nothing for an operator to configure, and no per-deployment account with anybody.

## Enrolment is two steps

`POST /auth/totp/enrol` mints a secret and stores it **unconfirmed**.
Nothing about signing in changes while an enrolment is unconfirmed.
`POST /auth/totp/confirm` verifies a code from the authenticator and only then switches the factor on, returning ten recovery codes.

A single-step enrolment would let a mis-scanned QR code, a wrong secret typed by hand, or a phone whose clock is off lock a member out of their own account, with no way back except an administrator.
The cost of the second step is one extra request; the cost of skipping it is a support ticket that can only be closed by somebody with ADMINISTRATOR, and a deployment may have exactly one such person.

The secret is returned as text as well as a URI, so a device with no camera, or a person whose camera cannot read the screen it is on, can still enrol.

## The one secret that is not hashed

Every other bearer secret in this codebase is stored only as a SHA-256 (`auth::hash_secret`).
A TOTP secret cannot be: it is a shared secret, and the server has to recompute HMAC from it on every verification.

So a database leak does hand an attacker the ability to generate valid codes for every enrolled account.
That is worth naming plainly rather than glossing.
What it does not hand them is a password, because those are Argon2id, so the factor still costs an attacker the password separately.
Recovery codes and sign-in challenges follow the hash-only rule as normal.

### Encrypting the column at rest, and why it is not done here

The option was weighed rather than skipped: encrypt `secret` with a key the server holds outside the database, so a leak of the database file alone yields nothing usable.

It would genuinely help in one real case, and it is the likeliest one: a stolen or misconfigured backup, a snapshot on the wrong volume, a database copied off a host by somebody who never had the host itself.
There is precedent for an environment-held secret, too - `push_relay_key` and `livekit_api_secret` both live in config rather than in a table.

Two things decided against it for now.

The existing server-held key cannot serve. The trust-on-first-use identity keypair is in `server_identity.secret_key`, in the same database file, so encrypting one column with it protects nothing: whoever has the file has both halves.
That means this needs a *new* operator-managed key, not a hook into something already there.

And a new key of that kind is an operator-critical secret with no recovery story. Lose it and every enrolled factor on the deployment is dead at once, with no way back except an administrator clearing each one by hand - which, on a single-admin deployment where the admin's own factor is among them, is a worse failure than the one being defended against.
On the common self-host shape the gain is also smaller than it looks: the key would sit in the `.env` beside the database, so anything that reads one usually reads the other, and the backup case is precisely the case an operator is most likely to capture both halves of.

So it is deferred rather than rejected. It becomes worth doing when there is a real key-management story to hang it on - a key that is not in the same directory as the data, and a documented "you must keep this" path - and at that point it should cover more than this one column.
Until then the honest statement is the one above: a database leak lets an attacker generate codes, and still does not give them a password.

### Update, 2026-10-18: now encrypted

The owner approved doing it, with a key that stays out of the database: `SLIMM_DATA_KEY`, or a 0600 `slimm-data.key` beside the database file, created on first start.
Secrets are sealed with XSalsa20-Poly1305, each bound to its own row, and rows stored in the clear by earlier versions are sealed at the next start.
The trade-off weighed above is accepted and documented: losing the key kills the stored factors, recovered by clearing them, and the key must be backed up apart from the database (docs/OPERATING.md, The data key).
The file shares a directory with the data by default, so it defends against a copied database or replica, not against a host compromise; `SLIMM_DATA_KEY` in `.env` is the way to separate them further.

## Verification, the window, and replay

A code is accepted within one thirty-second step either side of the current one, so at most ninety seconds.
One step, not two: phones drift and a person reads a code near the end of its window before typing it, so zero rejects honest attempts routinely, while each extra step multiplies what a single guess is worth.

A code is never usable twice.
The factor row stores the highest counter step already spent, and a code whose step is at or below it is refused even though the HMAC matches.
That kills replaying a code read off somebody's screen inside its own window, and it also retires every earlier still-in-window code in one move.

The sign-in challenge is separate and also single-use, so a challenge captured in transit cannot be replayed into a second session.
A **wrong** code deliberately leaves the challenge live, so one mistyped digit costs a retype rather than a fresh password round-trip; the attempt still counts against the failure budget.

## Two throttles, and why one is not enough

`ratelimit::Class::Totp` bounds the rate a caller may present codes at.
A persistent counter on the factor row bounds the total: five consecutive failures lock the factor for fifteen minutes, and the counter resets on success so a run of fumbles over a week never accumulates into a lock.

Neither alone is sufficient.
The limiter is in-process and keyed per address, so it resets on every deploy and an attacker with addresses to spare gets a fresh budget from each.
The lockout is in the database and keyed per account, so it survives a restart and does not care who is asking.

The limiter's burst is deliberately **above** the failure limit.
At or below it, the limiter answers first, the lockout never fires at all, and two people signing in from one office share one account's worth of attempts.
This was found by a test that asserted the lockout and was quietly passing on the limiter's 429; the relationship is now pinned by a unit test, and the integration test proves which control fired by making its final assertion through a second router with a fresh limiter.

### Can the lockout be used to lock somebody out?

Asked directly: if somebody knows my username, can they lock my factor for fifteen minutes by failing five codes?

No. Every path that can advance the failure counter is already behind the password or a session:

- `confirm_totp_enrolment` needs a live session.
- `verify_totp_for_change` needs a live session.
- `complete_totp_challenge` needs an unspent challenge, and a challenge only exists because `/auth/login` verified the password first.

A username alone reaches none of them, so the factor cannot be locked by a stranger. Somebody who *does* hold the password can lock it, and at that point the lockout is doing its job: they are the attacker it exists to stop, and making them wait is the point.

One genuine edge, worth naming because it is the awkward one. If a password has leaked to somebody whose aim is nuisance rather than access, they can keep the factor locked by failing codes, and while it is locked a recovery code does not work either - the lock is checked before anything is spent. The member then cannot sign in to change the password, and cannot change the password without signing in.

That loop has an exit, and it is the recovery path that already exists. An administrator issues a reset code; consuming it changes the password, which is what stops the griefer minting further challenges, and it deliberately does not touch the factor. The member then signs in with the new password and their own code, and the factor they still hold is still theirs.
So the case resolves without anybody's factor being cleared, which is the outcome to want. It is an accepted trade rather than a hole: a leaked password is a larger problem than a wait, and the answer to it is the same as it was before this feature existed.

A lockout is the one refusal that does not answer like the others.
Telling somebody "wait, you are locked out" discloses that this account has a factor and has been guessed at - which a determined attacker learns anyway by locking it themselves - and hiding it means a member who mistyped five codes is told a correct code is invalid and concludes their authenticator is broken.

## Recovery codes

Ten, shown exactly once, stored as hashes, each usable once.

They are 20 base32 characters in four dashed groups, `A3F7K-9MQ2X-P4RTV-8WYZ2`, and that shape is a correction rather than a first guess.
The first version reused the 43-character base64 secret every other bearer token here uses, which is right for a token a machine handles and wrong for one a person does: ten of them rendered as an unreadable block with no way to tell where one ended and the next began.
That was found by looking at the screen, not by a test, which is the argument for looking at the screen.

Grouping is what makes a code copyable by hand, and the lookup form is normalised - upper-cased, dashes and whitespace stripped - so retyping it without the dashes, or pasting it in lower case, is not read as a wrong code.
Just under 100 bits survives the reformatting, which still bounds the offline case a database leak would open; that matters here because recovery codes are stored as SHA-256 rather than Argon2, on the grounds that a code with this much entropy gains nothing from key stretching.

They work at sign-in and for the two changes that need current proof (disabling, reissuing), because "my phone is gone" is exactly the case they exist for.
Reissuing replaces the whole set: a set somebody has lost track of should not stay live beside the one they just wrote down.

## Proof to turn it on, and to delete the account (amended 2026-10-01)

**`POST /auth/totp/enrol`, `POST /auth/totp/confirm` and `DELETE /account` need the account password.**
`DELETE /account` also needs a current code or an unused recovery code while a factor is enabled.
A session token alone is refused with a 403, or a 400 when the code is the missing part.

The first version asked for proof to turn the factor off and to reissue recovery codes, and for nothing to turn it on.
That is backwards.
Turning it on is the move that locks the owner out: with only a stolen access token, enrol and confirm returned the secret and ten recovery codes, and the real owner's next password login got a challenge only the token holder could answer.
When that account was the sole administrator nobody could clear it.
Deleting an account is the other irreversible move a bearer token could make alone, and it freed the username as well.
Both now need the same kind of proof that turning the factor off needs, so a token is never worth more than the password behind it.

A wrong password is a 403, not a 401, because a client reads a 401 as "your session ended" and signs the member out for a typo.
The routes are rate limited on the password class (enrol and delete) and the TOTP class (confirm), so a stolen token cannot be used to guess the password.
In `schema/openapi.yaml` the `password` property, and the request body of enrol and delete, are declared optional.
The schema gate is additive-only (`docs/ci.md`), and a newly required property counts as breaking.
The server behaviour is as if they were required: a well-formed request without the password is a 400.

Confirming still does not revoke other sessions, for the reason in the section below: the sessions in question were minted by a password the member still holds.

## The operator's way back (amended 2026-10-01)

`slimm-server clear-totp <username>` clears a factor straight in the database.
It exists for the one case nothing else covers: the only administrator lost the authenticator and the recovery codes, so there is no session left to call `DELETE /admin/users/{id}/totp` from.
The image is distroless and the binary is the only tool in it, so the way back has to be in the binary.

It does what the admin route does and nothing less: it removes the factor, its recovery codes and its challenges, revokes every session, and writes a `totp_cleared` row to the moderation audit log.
The row has no actor, since nobody was signed in, and that absence is how an operator's clear is told apart from an administrator's.
The username matches case-insensitively, the way login does.
It needs file access to the database, which is the same trust as the database file itself, and it runs beside a live server for the reason `import-emoji` can.

## Sessions and device tokens

**Turning the factor on does not revoke anything. Turning it off does not either. An administrator clearing it revokes everything.**

Enrolling happens from a session the member controls, having proved the password, and disabling having proved the factor.
Signing their phone out for securing their account would be a penalty for good behaviour, and the sessions in question were minted by a password they still hold - the factor's job is to guard *future* sign-ins.
A member who is enrolling *because* they think their password leaked has a better tool already: the devices list and its per-device sign-out.

The administrator's clear is the opposite case and gets the opposite answer.
It removes a security control from an account nobody has proved they own, on the word of somebody who reached the administrator over a channel the server cannot see.
If that request came from whoever stole the account, the clear must not also leave them holding a live session.
So it revokes every session, which also clears each device's push registration, exactly as `consume_reset_code` already does and for the same reason.

## The admin-reset interaction

**An admin-issued password reset code does not clear, bypass, or re-key an enabled second factor.**
Consuming one sets a new password and revokes sessions, as it always has; the next sign-in with the new password still gets a challenge, answered by the same secret as before.

This is the decision most worth arguing, because the obvious objection is real: the administrator is already trusted with everything on a self-hosted deployment, so why withhold this?

Because impersonation is a strictly larger power than administration.
An administrator can already read every channel, remove members and change permissions - and every one of those acts is attributed to them.
Signing in *as somebody else* defeats that attribution, which is the property decision 0015 built the moderation audit trail for.

And because a factor that a reset code could walk past would be worth exactly as much as one administrator's say-so, which on most of these deployments is one person.
A member who deliberately enrols is asking the server not to let a password alone in.
The administrator has no way to verify, over whatever channel the request arrived on, that the person asking for a clear is the member.

The genuinely-lost-device case still has an answer, and a better one: `DELETE /admin/users/{id}/totp` is its own permission-gated act.
It clears the factor, revokes every session, and writes a `totp_cleared` row to the moderation audit log.

So an administrator who wants to take over an account can still do it - issue a reset code *and* clear the factor - and now leaves two audit entries saying so.
That is the trade: self-hosted trust plus an audit trail, not self-hosted trust plus a silent door.

## The deployment policy

Owner input, 2026-09-03: "MFA is interesting, not sure how it would work out as a selfhosted product, might need to be configurable per space."

`space_settings.totp_policy` is `off`, `optional` (the default) or `required_for_elevated`.

`off` refuses new enrolments and **keeps enforcing a factor somebody already enabled**.
Flipping a deployment setting must not silently weaken an account that chose to be harder to break into, and the disable path stays open either way, so anybody already enrolled can leave under their own steam rather than being stranded.

`required_for_elevated` is enforced at the *use* of an elevated permission, not at sign-in.
The obvious enforcement point - refusing a sign-in - would lock out the one administrator a fresh deployment has, before they could ever enrol, since enrolment needs a session.
So `http::extract::require_base_permission` refuses a caller who holds ADMINISTRATOR, has no confirmed factor, and is a person, with a 403 whose message says to turn on two-factor sign-in rather than "insufficient permissions".
Signing in, enrolling and confirming never pass through it, so nobody can be locked out; recovery codes and reset codes behave as before.
It covers the deployment-wide gates: `MANAGE_SERVER`, `MANAGE_ROLES`, member moderation, and the routes that name ADMINISTRATOR.
A bot is never asked, because it has no way to enrol and a permission that silently disables a bot is a bug.
Channel-scoped checks are not wired through it, so an unenrolled administrator still passes those by the administrator bypass.
Someone holding moderator bits without ADMINISTRATOR is not asked either.

## What is not built

- Passkeys. Still "later", as the research said.
- A second factor on the WebSocket or on refresh. Neither needs one: a refresh token is already device-bound and single-use per rotation, and a connect ticket is minted from an access token that a factor already gated.
