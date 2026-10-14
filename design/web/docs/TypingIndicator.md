---
category: Chat
---

# TypingIndicator

The "someone is typing" line that sits just above the composer: the pulsing `TypingDots` and a mono label.

## Wide vs compact

Same at every width (`typing_indicator.dart` does not read the layout class). The label simply wraps inside the composer width.

## Usage

```jsx
<TypingIndicator names={['kiki', 'Jonas Berg']} />
```

- Pass everyone typing except the reader. Names are sorted; one name reads "kiki is typing...", several read "Jonas Berg, kiki are typing...".
- With an empty list it renders nothing. Mount it only while someone types, so the dots do not animate forever.
- The label is secondary ink in the 13.5px code style. In the composer it sits 4px in from the left and 2px above the input bar.
