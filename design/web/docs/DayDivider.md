---
category: Chat
---

# DayDivider

The hairline band that separates two calendar days in the transcript, with the day name in mono at the centre.

## Wide vs compact

Same shape at every width. The side gutter follows the message rows: 20px at 600px and wider, 10px below (`paneGutterOf`), so the rule lines up with the text above and below.

## Usage

```jsx
<DayDivider label="Yesterday" />
```

- Put it above the first message of a new day. The caller decides; the row below keeps its normal top gap.
- Labels are "Today", "Yesterday", then "July 28", and "July 28, 2025" for another year.
- The label is secondary ink, 11px mono, semibold and tracked. Never accent: accent belongs to the unread marker.
