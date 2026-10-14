---
category: Forms
---

# Input

A text field on the raised surface. 1px border, an accent border plus a 2px accent ring on focus, and a danger border with error text underneath when invalid.

## Sizes

`sm` 32px, `md` 38px (default), `lg` 44px tall. The type size never changes with the height.

## Options

- `label` is a caption above the field. The Flutter field has none, so use it only in a form column.
- `icon` is a leading glyph, usually an `Icon`. `trailing` goes after the text: a shortcut hint or a clear button.
- `errorText` shows under the field and turns the border danger.
- `mono` uses IBM Plex Mono, for invite codes and server addresses.
- `multiline` with `minLines` and `maxLines` grows with its text.
- `counterMax` shows a soft character count that turns danger when exceeded.
- `disabled` dims the field.

## Usage

```jsx
<Input label="Invite code" mono placeholder="abcd-1234" errorText="That code has expired." />
```

- Error text is one short sentence, not a code.
- Search fields take `icon={<Icon name="search" />}` and a placeholder like "Search messages".
