---
category: Forms
---

# Input

A text field on the raised surface. 1px border, an accent border plus a 2px accent ring on focus, and a danger border with error text underneath when invalid.
The error takes the place of any helper note, so a form keeps its height when one appears.

## Sizes

`sm` 32px, `md` 38px (default), `lg` 44px tall. The type size never changes with the height.

## Options

- `label` is a caption above the field. The Flutter field has none, so use it only in a form column.
- `icon` is a leading glyph, usually an `Icon`. `trailing` goes after the text: a shortcut hint or a clear button.
- `helperText` is a standing note under the field, such as a format or a rule.
- `errorText` shows under the field in place of `helperText` and turns the border danger.
- `mono` uses IBM Plex Mono, for invite codes and server addresses.
- `multiline` with `minLines` and `maxLines` grows with its text.
- `counterMax` shows a soft character count that turns danger when exceeded.
- `disabled` dims the field.

## Usage

```jsx
<Input label="Invite code" mono placeholder="abcd-1234" errorText="That code has expired." />
<Input label="Password" type="password" helperText="At least 8 characters." />
```

- Error text is one short sentence, not a code.
- A field's error, including a server's answer about the value, goes in `errorText` under that field, never in a banner (`docs/design/errors-and-status.md`, rule 1).
- Search fields take `icon={<Icon name="search" />}` and a placeholder like "Search messages".
