---
category: Chat
---

# PollView

A poll inside a message: the question, one bar row per option, and a tally line.

## Wide vs compact

Width comes from the nearest `SlimRoot`. The card is capped at 360px and fills a narrower column. Option rows are 34px at 600px and wider and 44px below (`poll_view.dart` uses `AppTouchTargets` to reach the touch minimum). Bars, type and radii do not change.

## Usage

```jsx
<PollView
  question="When should we ship the call dock?"
  options={[{ label: 'Friday', votes: 6 }, { label: 'Monday', votes: 3 }]}
  yourVote={1}
  closesIn="Closes in 2 h."
/>
```

## Rules

- The bar fill is the strong border colour over a subtle track; a zero-vote option still shows its track.
- Your own vote gets a check in accent fill and a semibold label. Accent is allowed here and nowhere else in the card.
- The single top option, when there is no tie and at least one vote, gets a leading marker next to its percentage and a semibold label. The percentage column is hidden entirely until there is a vote.
- `closed` adds a `Closed` badge, drops the "Closes in" text and stops the rows reading as buttons. The footer says "No one voted." for a closed poll with no votes.
- Open polls with no votes say "No votes yet. Tap an option to vote."
