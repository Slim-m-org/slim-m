---
category: Surfaces
---

# CodeBlock

A fenced code block: a recessed mono panel with a language header, an optional action and notice, and an optional fold.

## Usage

```jsx
<CodeBlock
  language="rust"
  code={'fn main() {\n  println!("hello");\n}'}
  action={<Button size="sm" variant="ghost" label="Copy" />}
/>
```

- `code` is raw source with a small keyword, string, number and comment highlighter. `lines` takes pre-classified spans and wins over `code`.
- `language` is shown in the header in mono; the header renders even when empty.
- `notice` adds a band between header and body for a warning the reader must see first, such as before running code.
- `collapseAfterLines` folds a longer block behind a "Show more lines" bar.

## Rules

- A block is recessed; InlineCode is the raised opposite. Do not use a CodeBlock inside a sentence.
- Colours come from the theme-aware code tokens; do not recolour spans.
