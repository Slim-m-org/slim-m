import { Icon, Button, CodeBlock } from '@slim-m/design-system';

const rust = 'fn main() {\n  let room = "lobby";\n  println!("joined {room}");\n}';

export const WithAction = () => (
  <CodeBlock language="rust" code={rust} action={<Button size="sm" variant="ghost" label="Copy" icon="copy" />} />
);

export const WithNotice = () => (
  <CodeBlock
    language="javascript"
    code={'const greeting = "hello<U+200B>world";\nconsole.log(greeting);'}
    notice={
      <>
        <Icon name="warning" size={16} />
        <span>This block contains hidden characters, shown in place as &lt;U+XXXX&gt;. It cannot be run.</span>
      </>
    }
  />
);

export const Collapsed = () => (
  <CodeBlock
    language="python"
    collapseAfterLines={3}
    code={'import json\n\ndef load(path):\n    with open(path) as f:\n        return json.load(f)\n\nprint(load("config.json"))'}
  />
);
