---
category: Voice
---

# ParticipantTile

One person in a call. A raised 10px-radius card at 8:5 (height is 0.625 of the width) with the avatar centred, the name at the bottom, and a 22px badge at the top right.

## Width behaviour

The tile fills its parent, or takes a fixed `width`. The avatar is the largest size that fits above the 36px label band: 44px at the 144px minimum, 96px at 240px. Under 600px, ParticipantGrid hands it a compact avatar of 56px.

## Usage

```jsx
<ParticipantTile name="Mara Lindqvist" speaking width={240} />
<ParticipantTile name="kiki" muted local video="camera" width={240} />
```

- The badge is a mic (accent) when live, a mic-off (secondary) when muted, and a screen-share glyph when `video="screen"`.
- `video` draws a striped placeholder with a mono caption on a black surface and turns the name white. Real apps show the stream here; mocks never show a photo.
- `speaking` pulses the avatar ring; on a video tile it draws a static accent outline.
- `local` appends "(you)".
- Names truncate with an ellipsis; the "(you)" never does.
