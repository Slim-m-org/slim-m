---
category: Shell
---

# MemberList

The member pane: a MEMBERS count header, then sections by role and presence, with a row per person.
Use it as the `members` slot of `AppShell`.

## Width

It fills its container: 236px docked, and the same 236px in the right drawer on compact. Under 600 the rows grow from 36px to 44px for touch. The header stays 52px at every width.

## Rows

- Avatar (32px) with its presence dot, the name, and a second line for what they are doing (`activity` with an optional `activityIcon`).
- A role chip at the end when the person is not already under that role's own section; leave `role` off for rows inside it.
- A bot gets a square avatar and a neutral Bot tag instead of a role.
- Offline and hidden rows are dimmed.
- Section headings are uppercase with the count, such as ONLINE . 3.

## Usage

```jsx
<MemberList
  sections={[
    { label: 'Moderator', members: [{ id: 'm', name: 'Mara Lindqvist', status: 'online' }] },
    { label: 'Online', members: [
      { id: 'k', name: 'kiki', status: 'online', activity: 'Listening to Boards of Canada', activityIcon: 'listening' },
      { id: 'b', name: 'github-releases', status: 'online', bot: true },
    ] },
    { label: 'Offline', members: [{ id: 'j', name: 'Jonas Berg', status: 'offline' }] },
  ]}
/>
```

- Section order is yours: the app lists roles first, then Online, then Offline.
- `total` overrides the header count when the list is paged.
