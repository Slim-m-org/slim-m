# 0114 - The call stage fits the box

Status: accepted (the owner chose "Design D", fit to the box, bento style, from mockups)
Date: 2026-11-11
Amends: 0047 (the call dock; the stage above it)

## Context

The call's lounge view was a scrolling grid of people capped at 720px, or one share stage over a 128px filmstrip.
Order was join order, so a camera turned on by the tenth person sat past the end of the filmstrip and was clipped.
Several shares were an even grid that left most of the room empty.

The owner's words:

- "clean up the voice lounge view, It should scale better, depending on X amount of users, if someone turns on a camera with 10 people in a call, we dont see them if they are at the end, if 6 people are screensharing can we have a better gridding"
- "if we have 1 screenshare it should take up the entire top bit of space ... if there are 2 screenshares it should halve its size and make room for the other"
- "i dont like the black bars, we dont need to stretch beyond aspect ratio"
- then "bento box style": try layouts and keep the one that fills the box best.

Full-screen focus mode is not part of this change.

## Decision

The stage is one box (the pane minus the header, the banners and the dock clearance, full width).
`fitStage` in `client/packages/app/lib/src/features/voice/layout/stage_fit.dart` is a pure function that returns one rect per tile; `CallStageFitView` places them and animates rect changes.
The filmstrip, the capped grid and the share grid are gone.
Phone and desktop run the same code, because layout responds to width only (`docs/design/desktop-vs-mobile.md`).

### Order

By kind, never by who is talking, so nothing moves on speech: shares, then cameras, then audio-only people.
A camera turning on moves that person into the camera tier at once, so it is never hidden at the end.
The pinned item comes first: the share the viewer pinned (`shareWatchProvider`), else the newest share, else the first camera.
The viewer's own share only takes the pin when nothing else is shared.

### Candidates and scoring

Each candidate is laid out in the box and the one covering the most of it wins; ties (within half a percent) go to fewer rows.
A candidate where the pinned item is not the largest loses to one where it is, and so does one with a tile narrower than 108px, whenever a roomier one exists.

- Justified rows over every row count (the Flickr linear-partition idea), which also covers even grids of one aspect.
- Even grids over every column count.
- Pinned on top with justified rows below, the pinned height searched.
- Pinned at the left with justified rows at its right.
- Bento: pinned top-left, two items stacked at its right with their heights summing to the pinned height, the rest in rows below; the pinned height is solved so the block is exactly the box width, and limited by the height otherwise, so it scales down uniformly.

### Crop and letterbox

A share is sized to its aspect, so it is never cropped and has no black bars.
A camera may be cropped by at most 15% to line a row up with the box width, and never more.
Aspects come from the track when known and fall back to 16:9.

### Audio-only people

With content on stage they take a strip below or a column at the right as uniform tiles 96 to 160px wide, chosen with the content so the whole is the fullest; the strip wins unless the column is 15% better.
If that leaves no room for tiles at least 96px wide, they collapse to one row of chips ending in "+N".
With nothing else on stage they are a uniform grid over the whole box, with no width cap.

### One tile per person

A sharer appears once, as their share; a sharer with a camera also has their camera tile, which is a separate feed.
The viewer's own share is a calm "You are sharing your screen" tile with a visible Stop sharing button, not a live copy of their own screen.
Tapping a smaller share pins it.

## Consequences

- Tab order follows the stage order, cameras before audio-only people.
- A leaver's tile disappears at once; the old roster wrap's exit fade is not used here.
- Real track dimensions are not read yet; every share and camera lays out at 16:9 until a roster field carries them.
