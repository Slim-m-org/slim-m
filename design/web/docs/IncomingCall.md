---
category: Voice
---

# IncomingCall

The ring for an incoming DM call, with Decline and Accept. It sits above everything and vanishes on its own if unanswered.

## Width behaviour

- 600px and up: a floating card at the top of the window: 32px avatar, name, "Incoming call", then a danger Decline chip and an accent Accept chip. The rest of the window stays usable.
- Under 600px: a full-screen takeover on the base surface: 96px avatar, 24px name, "Incoming call", and Decline and Accept as large buttons across the bottom. Give the frame a height.
- This is desktop-vs-mobile rule 7.

## Usage

```jsx
<IncomingCall name="Mara Lindqvist" />
```

- Decline is always left, Accept (primary) right.
- Escape declines.
