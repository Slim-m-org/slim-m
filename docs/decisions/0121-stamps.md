<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0121 - Stamps: emoji and pictures on a shared screen and on the board

Status: accepted, 2026-11-16 (the server and the wire model are built; the client is not yet).
Amends [0096](0096-screen-overlay.md): its Relay, Privacy and Fade sections and "The board's own tools on the canvas".

## The ask

The owner, 2026-11-16: "add images to how we do the draw on streamers stream functionality, maybe we can paste an image onto their screen or emoji that also slowly vanishes like drawings, I want it to be sort of seamless with the canvas".
The ask behind 0096 already named "a funny meme", and what shipped was strokes, circles and notes.

Owner decisions, 2026-11-16:

- Emoji and pasted pictures and GIFs, both now.
- Stamps ride the existing "Viewers draw on my screen" setting, with no separate switch.
- On a shared screen a stamp lives 8 seconds and then fades over 1.5, after a short pop-in.
- It is placed with a tap, and a drag sizes it within a cap.
- There is one Stamp tool and one picker everywhere.
- On the board a stamp stays like any other item, and on a shared screen it fades.
- A stamp on a share never leaves anything on the board.

Defaults chosen for the owner, which he can change:

- A pasted picture is kept on the server for up to 24 hours, so the sharer's client can fetch it and the sharer can report it after it fades.
- An animated GIF shows one still frame on the native overlay and animates on in-app tiles.
- One person has at most 3 live stamps on one screen.
- A stamp's longest side is at most 30% of the shared screen's height.
- On Linux stamps land in the stream, as strokes already do.

## Decision in short

- A stamp is one thing everywhere: an emoji or a picture.
- An emoji is the same key a reaction stores: one emoji, a `:shortcode:`, or a custom emoji id.
- A picture is an attachment id, so an uploaded file, a pasted image or a picked GIF are the same thing.
- On a shared screen a stamp is a new kind of screen mark, `stamp`, relayed as `canvas.screen_annotation.updated` and faded by each receiver, like every other mark.
- On the board a stamp is a durable item: an emoji becomes the new `emoji` object kind, and a picture becomes an ordinary `image` object.
- A screen stamp enters through one REST route, `POST /channels/{channel_id}/voice/screen-stamps`, not the socket.
  Like a soundboard play (0118), it needs the call roster, the attachment rules and a refusal the sender can see.
- A picture stamp also writes one `screen_stamps` row (migration 0196).
  The row lets the sharer and the people in the call fetch the picture for 24 hours, holds the picture against the orphan sweep, and carries a report.
- Nothing about a screen stamp is written to the board's op log.

## One stamp everywhere

The owner defined seamless for the canvas in 0017: "as an end user, i shouldnt even know there is a difference between the items in the canvas".
0096 applied that idea to the pen, and stamps follow the same pattern.

- One content model: an emoji key or an attachment id, the same on a share and on the board.
- One picker, called Stamp, with three tabs.
  Emoji is the reaction picker's grid, with the Space's custom emoji and recent picks.
  GIFs is the composer's GIF search with favourites, shown when the deployment has GIF search.
  Picture offers "Choose a file" and paste.
- The picker follows surface rule 3: a popover anchored to the Stamp button on a pointer, and a bottom sheet on touch, through `showAppSheet`.
- Choosing something arms that stamp, and the Stamp button shows it as its sample, the way the pen button shows its colour (0073).
- One tool.
  On the call stage pill, Stamp is the fourth button after pen, circle and note, and the pill is still hidden on tiles under 220 px.
  On the board, Stamp joins the board tools, the tool wheel and the right-click tool row (0017).
- On the canvas, the board's Stamp tool stamps a share whose sharer allows drawing and can show stamps.
  Everywhere else it places a board item, including over a share that does not allow it, just as the pen inks the board over such a tile (0096).
- One geometry: a centre point and a size, where the size is the longest side.
  On a share the units are fractions of the shared screen, and on the board they are world units.
- One look: the same widget draws a stamp on the board, on a viewer's tile and on the sharer's preview.
  The native overlay draws a PNG baked from the same glyph or picture.

## Placing a stamp

- A tap places the armed stamp at the default size, centred on the tap.
  On a share the default longest side is 12% of the shared screen's height.
- Pressing and dragging sizes it, keeping the press point as its centre.
  The longest side is twice the drag distance, between 4% and 30% of the screen's height.
- The drag shows a local preview only, and the stamp is sent once, when the finger or button lifts.
- A picture keeps its own shape, so a wide picture comes out short and a tall one narrow.
  Because the size is the longest side, no stamp covers more than a square 30% of the screen's height on each side.
- Every renderer clamps a stamp's centre so the whole stamp stays on the screen, as notes are clamped today.
- Stamps do not rotate.
- The tool stays armed after placing a stamp, so another tap places another.
  Picking the tool again puts it down, as with the pen.
- Paste: Ctrl+V (Cmd+V on Apple) of a picture, with the pointer over a share that takes stamps, uploads the picture, arms it and shows it under the pointer.
  A tap places it, and Escape puts it down.
  Nothing reaches the sharer before the tap, so a screenshot meant for chat never lands on someone's desktop.
- Elsewhere on the board, paste works as it does today and puts a durable image at the centre of the view.
- A picture file dropped on a share that takes stamps is placed at the drop point, at the default size.
- On the board a tap places an item 130 world units on its longest side (12% of the shared area's height), and a drag sizes it up to 324 (30%).
  After that it moves, resizes, layers, erases and undoes like any other item.

## The wire

A viewer places a screen stamp with `POST /channels/{channel_id}/voice/screen-stamps`.
The body is `{id, target_user_id, x, y, size}` plus exactly one of `emoji` or `attachment_id`.
`id` is a client-minted UUIDv7 and keys the stamp everywhere.
`x` and `y` are the centre, 0 to 1 across the shared screen, and `size` is the longest side as a fraction of its height.
A success, and a replay of the same stamp, both answer 204.

The server relays the stamp as `canvas.screen_annotation.updated` with `kind: "stamp"`.
`annotation_id` is the stamp id, `points` is `[x, y]`, `size` is the size, and `ended` is always true.
The frame carries `emoji`, or it carries `attachment` (the attachment id) together with `animated`.
`animated` is decided by the server from the stored row: a GIF of at most 4 MiB.

A sharer's consent frame gains `stamps: true`, which says the sharer's client can show stamps.
The server relays it with the rest of the consent frame.

The socket never accepts `kind: "stamp"` from a client, so a stamp cannot skip the route's checks.

## What the server checks

In order:

1. The new `ScreenStamp` rate class allows 3 stamps at once, then one every 2 seconds, per person.
2. The fields must be well formed.
   `x` and `y` are finite and within 0 to 1, and `size` is clamped to 0.04 to 0.30.
   An emoji must pass the reaction validator, and a custom emoji id must name one of this Space's emoji.
3. The sender needs VIEW_CHANNEL and USE_CANVAS in the channel and no timeout in force, the same bar as ink.
   A picture also needs ATTACH_FILES.
4. The target must be someone other than the sender.
5. For a picture, the sender must be allowed to use the attachment, by the same rule a message uses (they uploaded it, or can see a channel that has it).
   It must be a PNG, JPEG, GIF or WebP of at most 8 MiB.
6. The SFU roster must show both people in the channel's call and the target sharing a screen.
7. The target's consent must be live.
   The server keeps each sharer's last relayed consent frame in memory and believes it for 15 seconds, as a viewer does.
   That frame must say both `allowed` and `stamps`.
8. If the target has blocked the sender, the answer is still 204, and nothing is stored or relayed.
   The sender cannot tell a block from a delivery.
9. For a picture, the server inserts the row.
   A replay with the same id and content does nothing, and the same id with different content is refused with 409.
10. The server publishes the relay event to the channel's canvas subscribers, as for any other screen mark.

Refusals are 400 for the fields, 403 for a permission, 403 "Join the call to stamp", 404 for an attachment the sender may not use, 409 "Their screen is not taking stamps right now", 429 for the rate, 501 when the server has no voice, and 503 when the SFU cannot be reached.
The sender's client removes its local copy of a refused stamp and says why in a warning banner on the tile (rule 6).

## Pictures: where they live and who can see them

- A picture is an ordinary attachment.
  It comes from the existing upload route, or from the existing GIF route for a GIF or a favourite.
- A `screen_stamps` row records the stamp id, the channel, the sender, the target, the attachment, the time and an optional report.
- The attachment fetch route gains one rule, checked after its existing one.
  A caller may fetch a picture named by a `screen_stamps` row that is less than 24 hours old if they are its target, or if they are in that channel's call now and can view the channel.
  A moderator who holds MANAGE_MESSAGES and VIEW_CHANNEL there may also fetch the picture of a reported row.
- The new rule applies to fetching only.
  It is not part of the rule that lets someone attach a picture to a message, so seeing a stamp never lets anyone post it.
- Knowing an attachment id grants nothing, as before.
- Clients fetch the bounded still preview the server already derives (`?w=640&still=true`).
  It keeps transparency as WebP and is capped at 40 megapixels.
- An in-app tile fetches the original only when the relay says `animated`.
- Clients keep stamp pictures in memory only, never in the persistent image cache, and drop them when the call ends.
- The hourly attachment sweep deletes stamp rows older than 24 hours that no open report holds.
  In the same pass, the orphan sweep reclaims any picture nothing else holds, because `screen_stamps` joins the tables that keep an attachment alive.
- A stamp on a share never creates a canvas object, a canvas op or an attachment link.
- Account deletion and data exports record both user columns as kept until the sweep, since a row lives a day.

## Reporting a picture after it fades

- The sharer's "Pictures on your screen" sheet lists the pictures stamped on their screen in the last 24 hours, newest first.
  Each row shows the picture, who sent it and when, with Report and Block.
- The sheet opens from the share options menu while sharing, and from Voice settings under "Sharing and preview" at any time.
  So a sharer who stopped sharing in a hurry can still report.
- It follows surface rule 3: a popover on a pointer and a bottom sheet on touch.
- A report has `subject_kind: "screen_stamp"` and names the stamp.
  The server checks that the reporter is the stamp's target and that the row still exists.
  It then files the report about the sender, with the stamp's channel, and links the row to the report.
- A second picture from the same person, while that report is still open, joins the same report.
  So one report can carry several pictures.
- A linked row, and its picture, are kept past 24 hours while the report is open.
  The first sweep after the report is resolved or dismissed removes both.
- The moderation queue shows the pictures beside the reason.
  An older client reads the new kind as a report about the person, which it is.
- Only the sharer can report a faded picture (see the questions below).

## Showing a stamp

- Each receiver runs the clock itself, as for every other mark, and nothing about time travels on the wire.
- A stamp's clock starts when it is ready to paint.
  A standard emoji is ready at once, and a custom emoji or a picture when its image has arrived.
- A stamp that is not ready within 5 seconds of arriving is dropped rather than shown late.
- It pops in over 180 ms (`duration.base`), scaling from 60% to full size with a slight overshoot.
  It then holds for 8 seconds and fades over 1.5.
- With the system's "reduce motion" setting on, there is no pop-in, and a GIF shows its still frame.
- One person has at most 3 live stamps on one screen, and placing a fourth starts the fade of their oldest at once.
- One screen has at most 12 live stamps in all, and past that the oldest starts to fade.
- Both caps sit inside 0096's limit of 48 live marks.
- A stamp from someone the receiver has blocked is dropped before anything is fetched for it.
- When a sharer withdraws consent, every board on every receiver is cleared at once, stamps and all other marks alike.

## On the sharer's desktop

- Dart decides what is drawn, and the runner only paints it (0096).
- Dart bakes each stamp image to a PNG whose longest side is 512 px.
  A standard emoji is drawn with the app's colour emoji fonts, a custom emoji comes from the emoji cache, and a picture comes from its still preview.
  Each source image is decoded within size bounds before it is drawn.
- Dart sends each PNG once in its own `putImage` call, keyed by what it shows: `e:` plus the emoji, `c:` plus a custom emoji id, or `a:` plus an attachment id.
  It is never sent inside a draw frame, because the draw queue may drop a waiting frame.
- A draw frame names the key, the centre, the size, the pop-in scale and the alpha.
  A stamp whose image the runner does not hold yet is left out of the frame.
- The runner keeps at most 24 images.
  Dart removes the least recently used one with `dropImage`, and both sides forget every image whenever the window is shown or hidden, as with call-panel avatars.
- Linux paints a stamp with cairo, through a scaled source with a good filter and `cairo_paint_with_alpha`.
- Windows paints it with GDI+, using `DrawImage` with a colour matrix for the alpha and high-quality bicubic scaling.
- The runner only ever decodes PNGs that Dart made, and refuses any image wider or taller than 1024 px.
- On Windows, stamps stay out of the capture with the rest of the overlay, both on a shared screen and on a followed window (0117).
- On Linux, stamps land in the stream, so viewers see each one twice.
  A viewer who blocked the stamper still sees it in the video, and the sharer's remedy is to block that person or turn the setting off.
- Sharers on GNOME, macOS, the web or a phone see stamps only in their in-app preview, as with every other mark.

## On the board

- An emoji stamp is the new `emoji` object kind, and its props carry the emoji key, checked by the reaction validator.
  It is painted through the image path, from a bitmap drawn by the same baker.
- A picture stamp is an `image` object, and nothing about images changes.
- `canvas_objects.kind` has no CHECK constraint, so the new kind needs no migration.
  The server's `KINDS` and `CLEAR_KINDS` lists gain `emoji`.
- An older client draws nothing for an `emoji` object until it updates.

## Rate limit

`ScreenStamp` is a count-based class with a burst of 3 and one more every 2 seconds, per person, shaped like the soundboard's (0118).
Each person can have at most 3 live stamps on a screen anyway, so a faster rate would only replace their own stamps.
New pictures also fall under the existing Upload class.

## Mixed versions, server first

- The server half lands first, because main deploys it continuously.
- With a new server and older clients, nobody can post a stamp.
  Older clients ignore the stamp kind and the new fields, read a screen-stamp report as a report about a user, and draw nothing for `emoji` objects.
- A new client offers the Stamp tool on a share only when the server lists the `screen_stamps` capability on `/version` and the sharer's live consent says `stamps: true`.
  So a stamp never reaches an older sharer's screen, which would drop it.
- An older server drops `stamps` from consent frames and does not serve the route, so a new client connected to it shows no Stamp tool on shares.
  The board's Stamp tool is hidden there too, because the `emoji` kind arrives with the same capability.
- The runner and the Dart side ship in one binary, so they never disagree.

## Privacy

This replaces 0096's line "Nothing a viewer draws is stored on the server or the sharer's disk" for pictures.

- Strokes, circles, notes and emoji stamps are still never stored.
- A picture stamp is stored for up to 24 hours, and longer only while a report about it is open.
  It can be read by its sender, the sharer, the people in that call, and moderators of a report about it.
- Nothing a viewer stamps is written to the sharer's disk, apart from custom emoji in the emoji cache that already exists.

## Why not

- Picture bytes on the socket: every inbound frame is capped at 4 KiB, and its bytes count against the same budget as ink.
- An in-memory fetch grant: every deploy from main restarts the server.
  That would cut the sharer off mid-call and lose the evidence for a report, and nothing would hold the picture against the sweep.
- Adding the sharer as an uploader in `attachment_uploaders`: that would let them post the picture as well as see it, and it does not cover the rest of the call.
- A hidden canvas object: it would put the stamp on the board, which the owner ruled out.
- Sending stamps over the socket: the roster check, the attachment rules and a refusal the sender can see belong on a request, as with the soundboard.
- A separate switch for stamps: the owner decided against one.

## Not done

- Rotation.
- Animation on the native overlay.
- Placing a stamp from the keyboard.
- Stamping from the full-screen video view, which has no pen either (0096).
- Animated WebP and PNG show their first frame everywhere, and only GIFs animate on tiles.

## Questions for the owner

This record assumes each recommended answer until the owner says otherwise.

1. Should stamps rotate?
   Recommended: no.
   Other options: a rotate handle on board items only, or a two-finger twist on touch.
2. What should paste over a share do?
   Recommended: arm the picture under the pointer and place it on a tap.
   Other option: place it under the pointer at once, which is faster but lets a clipboard accident land on someone's real desktop.
3. Who can report a faded picture?
   Recommended: the sharer only.
   Other option: everyone who was in the call, which needs the server to remember who was there.
4. How many live stamps should one screen hold in all?
   Recommended: 12.
   Other options: no total cap beyond 3 per person, or 6.
5. How big should stamps be?
   Recommended: 12% of the screen's height by default and 30% at most.
   Other options: 10% and 25%, or 15% and 40%.
6. Should a picture stamp need ATTACH_FILES?
   Recommended: yes, so a channel that bars attachments also bars pictures on screens.
   Other option: USE_CANVAS alone, as pasting an image on the board needs today.
7. For 8 seconds, a picture on a real desktop could imitate a system dialog. Should the overlay mark it?
   Recommended: no frame, so a stamp looks the same everywhere.
   Other option: a thin hairline frame around pictures on the overlay only.
8. Should there be a shortcut that clears every mark and stamp from my screen?
   Recommended: not now, since turning the setting off already clears them.
   Other option: a remappable call shortcut, like "Toggle call overlay".
9. Where should "Pictures on your screen" live?
   Recommended: the share options menu and Voice settings.
   Other options: the share options menu only, or the call header's menu.
