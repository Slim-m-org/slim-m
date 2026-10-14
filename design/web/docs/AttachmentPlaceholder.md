---
category: Chat
---

# AttachmentPlaceholder

A striped stand-in for an image or video attachment inside a `MessageRow`, with a mono caption naming what belongs there. Mocks never use real or generated photos.

```jsx
<MessageRow author="Jonas Berg" time="09:41" body="New layout for the rail" attachment={<AttachmentPlaceholder caption="screenshot · rail-v2.png · 412 KB" />} />
```

- `caption` defaults to `image`; say what the file is (`screenshot · name.png · size`).
- It is 420px wide at most and shrinks with the message column.
