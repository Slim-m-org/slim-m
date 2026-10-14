---
category: Profile
---

# MemberProfile

A member's profile card, opened from a name or avatar anywhere in the app. It shows who they are, what they are doing, and what you can do about them.

## Width

The same content lives on two surfaces, so `presentation` is explicit and the caller picks it from width (desktop-vs-mobile rule 3).

- `popover` (default): a 300px floating Menu anchored next to the avatar, for windows 600px and wider. Rows are 34px. Anchoring is the host's job; the component only draws the card.
- `sheet`: a bottom sheet with a drag handle, full width, rows 48px and a 44px "Show more" target, for windows under 600px (`kCompactWidth`). Place it at the bottom of a `SlimRoot`.

## Content, top to bottom

- Header: 44px avatar with presence dot, display name (semibold), `@username` line (account name after a nickname, pronouns), then the presence word or, in a shared call, an accent "in <channel> with you" line with a speaker glyph and a speaking ring.
- `about`, an `activity` card (heading, title, subtitle on a 40px cover), role chips (mono 10px, hairline) followed by the join date, a timeout callout when `timedOutFor` is set.
- Bots (`isBot`): square avatar, and "Commands - answers to <prefix>" listing the first three commands with "Show N more" for the rest.
- Actions: Message, a private note field ("only you"), Moderate... (`canModerate`), Report user, Block (danger) or Unblock. Your own card shows only Profile settings.

## Usage

```jsx
<SlimRoot style={{ width: 390, height: 640, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
  <MemberProfile
    presentation="sheet"
    displayName="Mara Okafor"
    username="mara"
    status="online"
    statusWord="online"
    roles={['Moderator']}
    joinedLabel="joined Mar 2025"
    canModerate
  />
</SlimRoot>
```

- There is no banner image and no Call button in the app; calling happens from the voice channel, not the card.
- Roles are never individually coloured. The avatar ring colour comes from the member's profile colour, and only when they are not in a call with you.
- Pass the join date and presence word already formatted; the card does no date maths.
