---
category: Chat
---

# LinkEmbed

The unfurled preview under a message that contains a link: site name, title, description and an optional image in a hairline card.

## Wide vs compact

Same card at every width. It is capped at the 760px message column and shrinks to whatever column the `SlimRoot` gives it; an image is capped at 380px and never overflows the card. Nothing in `link_preview_card.dart` branches on layout class.

## Usage

```jsx
<LinkEmbed siteName="github.com" title="Add the call dock to the design system" description="Ports the dock from the Flutter app." image />
```

## Rules

- No fill, a 1px subtle border, 6px radius and 8px padding. Elevation is border-first.
- The title clamps to two lines and the description to three; the site name and author stay on one line and ellipsize.
- Show nothing when there is no text and no image; a preview with an image only is still valid.
- The `image` prop takes a URL, or `true` for the striped stand-in. Images are cropped to cover, 6px radius, hairline border.
- Place it 4px below the message body, one card per link. The embed-card variant with an accent stripe and a raised fill is not covered here.
