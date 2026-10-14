---
category: Chat
---

# UnreadDivider

The "NEW" marker above the first unread message: a half-strength accent rule with the label at the right edge.

## Wide vs compact

Same shape at every width. The gutter follows the message rows: 20px at 600px and wider, 10px below.

## Usage

```jsx
<UnreadDivider />
<MessageRow author="kiki" time="9:43a" body="Did you see the new build?" />
```

- At most one per channel, directly above the oldest unread message. It sits 14px below the previous row and 6px above the next.
- The rule is the accent fill at 50% and the word is accent text; this is one of the places accent is allowed to mark state.
- If a day starts at the same row, the DayDivider goes first and this one follows it.
