---
category: Chat
---

# Mention

An @mention inside message text: an accent-soft pill with accent text. Mentions of you are one of the accent's seven roles, so this is the only way message text gets accent colour; the row itself is never highlighted.

```jsx
<MessageRow author="kiki" time="14:02" body={<>Can you look at this, <Mention>@Mara Lindqvist</Mention>?</>} />
```

- Children are the visible text, including the leading `@`.
- Use it for people, roles (`@Moderator`) and `@everyone`; channels are written as `#name` in plain text.
