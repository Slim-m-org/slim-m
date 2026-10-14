---
category: Voice
---

# VoiceJoinBar

The card at the top of an idle voice channel: who is in the call, who is online, and one primary Join. Joining always starts you muted.

## Width behaviour

- 600px and up: a mono status line ("2 in the call - last call yesterday"), the subtitle ends with "joining starts you muted", and the button reads "Join muted" (empty) or "Join - N here".
- Under 600px: no status line and no muted hint; the title shortens to "Nobody's here" and the button to "Join".

## Usage

```jsx
<VoiceJoinBar here={['Mara Lindqvist', 'kiki']} online={['Jonas Berg']} lastCall="yesterday" />
```

- More than two names collapse to "Mara and 2 others are here".
- `errorMessage` adds a persistent error state under the bar and relabels the button "Try again". Never a toast.
- The app shows no avatars in this bar; names carry it.
- The last-call timeline below the bar is a separate surface and is not part of this component.
