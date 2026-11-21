<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0130 - One form signs in and creates accounts, and the server says which

Status: accepted, 2026-11-21.

## The report

The owner, 2026-11-21: "Multiple time I've had people try to sign back in and they accidentally somehow create a new account instead of logging in".
The live deployment had three pairs that fit: an account with history, and a second one with no messages made minutes before a sign-in to the first.
Every second account was made on a second device.

## What caused it

The sign-in screen had two modes, signing in and creating an account, that showed the same two fields.
Which one it opened on was a guess: a fresh install choosing "Join the official Space" opened on creating an account, to save a newcomer a tap.
A fresh install is as often somebody's second device.
They typed their own username and password into the create form.
A name that was taken said so, and they picked another.
A name they misremembered by a letter was free, and became an account.

## Decision

There is one form: username, password, Continue.
It never opens on creating an account because of how it was reached.

- The client asks the server whether the username has an account (`POST /auth/username/check`) before it sends the password anywhere.
- A username with an account signs in.
  A refusal after that is about the password alone, and says which account it was wrong for.
- A username with no account opens the create step on the same screen.
  It says there is no account by that name on this Space, asks for the password a second time, and creates the account only when the person confirms.
  This is where a misremembered username is caught.
- The create step still signs the person in when the server answers that the name is taken and the password is that account's.
- The password is confirmed on creation because there is no email recovery: a typo there locks the account until an admin issues a reset code.

Two cases still open on the create step, because nobody can have an account yet or the server cannot say:

- an unclaimed Space (decision 0052), where the first account becomes its admin;
- an invite from onboarding, on a server older than the username check.

## The server route

`POST /auth/username/check` takes `{"username"}` and answers `{"exists"}`.
It is unauthenticated, validates the name the way registration does, and matches the way registration does: any letter case, live accounts only, bots included.
It writes nothing and hashes nothing.

It discloses nothing new.
`POST /auth/register` already answers "username is already taken" for the same question.
It has its own rate budget (the invite-check class, a burst of 10 per client), tighter than a general read because the answer is worth guessing at, and separate from the password budget so a lookup never costs a sign-in attempt.

`GET /version` lists the capability `username_check`.

## The button that stays

"Create an account instead" is still under the form on every server.
A newcomer looks for it, and it is the only way across on a server that cannot look names up.
It was briefly shown only once such a server had answered, and the form moved under the person when it arrived.
Tapping it is a choice rather than a guess, and the create step it opens still signs in someone whose name and password match an account.

## Older servers and a spent budget

A client that knows the server lacks the capability does not ask.
A lookup that is refused as unknown or rate limited is treated as no answer: the sign-in goes ahead as it always did, and a refusal reads "Wrong username or password."

## What it costs

A newcomer on the official Space now takes one more step than under the old default, which is the step that asks them to confirm.
A newcomer who picks a name that is taken is told the password is wrong for that account and that the name is taken, in one line.

## Alternatives not taken

- Opening on "Sign in" instead: it moves the wrong guess onto newcomers and still leaves two forms that look alike.
- Making the two forms look different: it depends on people reading the title, which is what did not happen.
