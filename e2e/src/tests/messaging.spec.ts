// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, test } from '../fixtures';
import { L } from '../labels';
import { expectSent, openChannel, reactionsOn, send, toolbar, uniqueText } from '../messages';

const CHANNEL = L.TEXT_CHANNEL;

test.describe('messaging between two people', () => {
  test.beforeEach(async ({ signedIn }) => {
    await test.step('alice and bob both open #general', async () => {
      await openChannel(signedIn.alice, CHANNEL);
      await openChannel(signedIn.bob, CHANNEL);
    });
  });

  test('a message from alice appears for bob live, and his reply appears for her', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const hello = uniqueText('hello from alice');
    const reply = uniqueText('and a reply from bob');

    await test.step('alice sends a message', () => send(alice, hello));
    await test.step('bob sees it without reloading', () => bob.see(hello));
    await test.step('bob answers', () => send(bob, reply));
    await test.step('alice sees the answer', () => alice.see(reply));
    await test.step('both still see the first message', async () => {
      await alice.see(hello);
      await bob.see(hello);
    });
  });

  test('an edit reaches the other person', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const before = uniqueText('before the edit');
    const after = uniqueText('after the edit');

    await test.step('alice sends a message and bob sees it', async () => {
      await send(alice, before);
      await expectSent(alice, before);
      await bob.see(before);
    });
    await test.step('alice edits it from the message toolbar', async () => {
      await toolbar(alice, before, 'Edit');
      await alice.see('Editing');
      await alice.replaceFocusedText(after);
      await alice.click('Save');
    });
    await test.step('bob sees the new text and the old text is gone', async () => {
      await bob.see(after);
      await bob.seeNo(before);
      await expect(bob.text('edited').first()).toBeAttached();
    });
  });

  test('a delete reaches the other person', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const doomed = uniqueText('this one gets deleted');

    await test.step('alice sends a message and bob sees it', async () => {
      await send(alice, doomed);
      await expectSent(alice, doomed);
      await bob.see(doomed);
    });
    await test.step('alice deletes it from the message menu and confirms', async () => {
      await toolbar(alice, doomed, L.MENU_MORE);
      await alice.click(L.MENU_DELETE);
      await alice.see('Delete message?');
      await alice.click('Delete');
    });
    await test.step('it disappears for both of them', async () => {
      await alice.seeNo(doomed);
      await bob.seeNo(doomed);
    });
  });

  test('a reaction left by bob shows on alice\'s message for both of them', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const text = uniqueText('react to this');
    const grinning = '\u{1F600}';
    await test.step('alice sends a message and bob sees it', async () => {
      await send(alice, text);
      await expectSent(alice, text);
      await bob.see(text);
    });
    await test.step('bob opens the reaction picker from the message toolbar and picks the grinning face', async () => {
      await toolbar(bob, text, L.ADD_REACTION);
      await bob.click('grinning face');
    });
    await test.step('a reaction chip with a count of one appears for both', async () => {
      for (const app of [alice, bob]) {
        await expect.poll(() => reactionsOn(app, text), { message: `${app.name} should see the chip` }).toEqual([`${grinning} 1`]);
      }
    });
  });

  test('a reply quotes the message it answers on both screens', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const original = uniqueText('a question to answer');
    const answer = uniqueText('the answer');

    await test.step('alice asks and bob sees it', async () => {
      await send(alice, original);
      await expectSent(alice, original);
      await bob.see(original);
    });
    await test.step('bob chooses Reply on that message and sees who he is replying to', async () => {
      await toolbar(bob, original, 'Reply');
      await bob.see('Replying to Alice');
    });
    await test.step('bob sends the answer', () => send(bob, answer));
    await test.step('both see the answer quoting alice', async () => {
      for (const app of [alice, bob]) {
        await app.see(answer);
        // Bob's own message names alice plainly; on alice's screen the mention is highlighted as @Alice.
        const quote = new RegExp(`Reply to @?Alice: ${original}`);
        await expect(app.page.locator('flt-semantics[role="button"]').filter({ hasText: quote }).first()).toBeAttached();
      }
    });
  });

  test('a reply inside a thread reaches the other person who opens it', async ({ signedIn }) => {
    const { alice, bob } = signedIn;
    const root = uniqueText('a thread root');
    const inside = uniqueText('a reply inside the thread');

    await test.step('alice posts the root message and bob sees it', async () => {
      await send(alice, root);
      await expectSent(alice, root);
      await bob.see(root);
    });
    await test.step('alice opens a thread on it from the message toolbar', async () => {
      await toolbar(alice, root, L.REPLY_IN_THREAD);
      await alice.see(L.THREAD_HEADER);
      await alice.seeField(L.THREAD_COMPOSER);
    });
    await test.step('she replies inside the thread', async () => {
      await alice.type(L.THREAD_COMPOSER, inside);
      await alice.click(L.THREAD_SEND);
      await alice.see(inside);
    });
    await test.step('bob opens the same thread and sees the reply', async () => {
      await toolbar(bob, root, L.REPLY_IN_THREAD);
      await bob.see(L.THREAD_HEADER);
      await bob.see(inside);
    });
  });
});
