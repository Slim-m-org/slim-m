# 0099 - Private scenes

Status: accepted; built
Date: 2026-10-28

## The ask

The owner on Word Guess (2026-10-19): "wordle game is currently an on the fly game, but normally its just a game played by multiple people on their own devices at their own time (google wordle) but thats not how its implemented, its missing the social portion".

## What was wrong

An `app` is a shared surface (decision 0021): every frame a module returns is stored against the message and broadcast, so every viewer sees the same board.
That is right for a game played together and wrong for one played alone beside other people: whoever guessed would show their letters to the channel.
The scene contract had no way to answer one person.
Making the board private with state kept in the scene does not work either, because on a shared surface the host hands the module the stored frame's state, not the presser's.

## Decision

A scene whose top-level `private` is `true` is an answer for the person who pressed, and for no one else.

- On an app surface the host runs the command as usual and returns the output to the caller, but does not store it as the surface's frame and does not broadcast it. The next viewer to load the message still sees the last shared frame.
- The client shows a private frame to that viewer in place of the shared one, and holds shared frames back while it is up, so another player finishing does not pull their board away. A control that makes the module answer with a scene that is not private (Word Guess calls it close) brings the shared frame back.
- A code block run is not a surface: its output is stored for everyone and `private` is ignored there.
- The module keeps what a private board needs in its own storage, keyed by the caller id, never in `state`: the host gives a shared surface the stored frame's state whatever the client sends. That is also what makes a board unforgeable, since the viewer's copy of the state decides nothing.
- It is add-on API 2. A module that sends private scenes declares `"addon_api": 2`, and a server that supports only 1 refuses to install it ("update the server") instead of showing the letters to the whole channel. API 1 modules install and run exactly as before.

## Not decided here

- A private frame is never stored, so it is gone on reload: a player reopens their board with a control that asks the module for it.
- Notes (sound) in a private scene play for the viewer as for any scene they act on.
