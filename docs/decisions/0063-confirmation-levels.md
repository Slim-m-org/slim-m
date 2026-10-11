# 0063 - How strongly each permanent or security action is confirmed

Status: accepted, 2026-10-11.

## The problem

The owner asked that "all permanent/important decisions are locked behind a confirmation relevant to the task, login/password/2fa things need to have password confirmation" (2026-10-05).
Most destructive actions already went through `confirmDangerousAction`.
Three did not match the rule: shortening the message retention window deleted history on one tap, and an administrator could issue a password reset code or clear another member's two-factor with only a session token.

## The levels

- **None**: the action is undone by doing the opposite, or it only touches the caller's own view.
  Adding friction here trains people to click through the dialogs that matter.
- **Confirm** (`confirmDangerousAction`): the action is permanent or disruptive to others.
  The title names the object and the message says what happens, in the task's words.
- **Password** (`showReauthSheet`, enforced by the route): the action changes or opens a way into an account.
  A session token alone must not be enough, so the server refuses without the proof, not only the client.
  A person sends their own password; a bot has none and authenticates with its own token, so it sends nothing.

## The table

| Action | Level | Where |
| --- | --- | --- |
| Delete account | Password (plus a code when two-factor is on) | `DELETE /account` |
| Turn two-factor on (enrol, confirm) | Password | `/auth/totp/enrol`, `/confirm` |
| Turn two-factor off, replace recovery codes | A current code or recovery code | `/auth/totp/disable`, `/recovery-codes` |
| Administrator issues a password reset code | Password (new) | `POST /admin/users/{id}/reset-code` |
| Administrator clears a member's two-factor | Password (new) | `DELETE /admin/users/{id}/totp` |
| Sign out one device, all other devices, stale devices | Confirm | devices section |
| Sign out this device | None | reversible by signing in |
| Change password while signed in | Not built | follow-up, see below |
| Set a shorter message retention window | Confirm (new) | performance screen |
| Loosen or turn off retention | None | deletes nothing |
| Delete a channel, category, role, custom emoji | Confirm | settings and admin screens |
| Delete a message, several messages, a reported message | Confirm | message actions, report card |
| Remove a member, bulk remove, time out, eject from a call | Confirm | member actions |
| Delete a removed member's account | Confirm | removed members screen |
| Revoke a bot, a webhook, an invite; rotate a webhook | Confirm | admin screens |
| Uninstall a Dock module, remove a Dock source | Confirm | Dock screens |
| Clear a canvas | Confirm | canvas overflow menu |
| Delete one canvas object | None | the canvas has undo |
| Disable a Dock module, grant or revoke a permission, assign or remove a role | None | a toggle, undone by the opposite |
| Block or unblock, hide a DM, unpin, remove a reaction, clear a nickname or status | None | reversible |

## Why a password and not a code for the administrator routes

A reset code is a way into any account, and clearing two-factor removes the only thing that protects an account from a leaked password.
The administrator's two-factor code would prove the second factor, but an administrator without one enrolled would have nothing to give, so the password is the one proof every person has.

## Not done

- An in-session change-password flow does not exist (`/auth/reset` takes an administrator code only).
  If it is added, the route must take the current password.
- Granting ADMINISTRATOR to a role or a bot is a toggle with no confirmation.
  It is reversible, so it stays as is until the owner says otherwise.
