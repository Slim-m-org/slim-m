# slim-m end-to-end tests (Playwright)

These tests drive the real app the way a person does, with a video of every user for every test.
They run beside the Python harness in `scripts/e2e.sh`, which stays until the scenarios here reach parity with it.

Nothing is mocked.
`scripts/e2e-stack.sh` boots a LiveKit SFU in Docker, the release server binary, the Flutter web build, and a seeded deployment with two accounts (`alice` and `bob`) and a voice channel.
Each test opens one browser context per user, so each user has their own video.

## Run it

You need Docker, Rust, Flutter (the version in `client/pubspec.yaml`), Python 3, Node 22 and `curl`.

```bash
cd e2e
npm ci
npx playwright install chromium     # add --with-deps on a fresh Linux box
npm test                            # boots the stack, runs the suite, tears the stack down
```

The first run builds the server and the web client, which takes several minutes.
Later runs reuse both.
After a client change, run with `E2E_REBUILD=1` or the old web build is served.

```bash
npm run test:headed                 # watch the browsers
npm run test:ui                     # Playwright's UI mode, to step through tests
npx playwright test messaging       # one spec file
npx playwright test -g "an edit"    # one test by name
```

To iterate without booting the stack every time, keep it up:

```bash
../scripts/e2e-stack.sh up          # once
E2E_STACK_UP=1 E2E_KEEP=1 npx playwright test
../scripts/e2e-stack.sh down        # when done
```

The server rate-limits password sign-ins to about twenty a minute from one address.
The suite signs each user in once per run and restores that session for the other tests, so a long loop of reruns against one stack can still hit the limit.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `E2E_WORK` | `/tmp/e2e` | Work dir: database, logs, `stack.json` |
| `E2E_API_PORT` | `8095` | The server |
| `E2E_WEB_PORT` | `8356` | The web build |
| `E2E_LK_PORT` | `7880` | LiveKit |
| `E2E_STACK_UP` | unset | `1` means a stack is already up, so do not boot one |
| `E2E_KEEP` | unset | `1` leaves the stack running afterwards |
| `E2E_REBUILD` | unset | Rebuild the web client even if a build exists |
| `E2E_LINGER_MS` | `700` | How long each step's end state stays on screen, so the video shows it |

The suite refuses to run against anything that is not a local stack, and never against the live deployment (`scripts/lib/e2e_stack_guard.py`).

## Where the results land

- `e2e/playwright-report/index.html` is the HTML report. Open it with `npm run report`.
- Every test has `alice.webm` and `bob.webm` attached, and a trace you can open with `npx playwright show-trace`.
- `e2e/test-results/` holds the same files per test, plus a screenshot at the end.
- `$E2E_WORK/server.log` is the server's log.

CI uploads all of these as the `e2e-playwright-report` artifact, including when the run fails.

## How the app is driven

Flutter paints to a canvas, so the app is only scriptable once its accessibility tree is on.
`FlutterApp.open` turns it on, and every widget then becomes an `<flt-semantics>` element.
A widget's name is its `aria-label` when it has one and its text otherwise, and text fields are real `<input>`s.
`src/flutter.ts` hides that behind `click`, `type`, `see`, `seeNo`, `scrollUntil` and friends, all of which wait.

The accessible names come from `scripts/lib/e2e_labels.py`, the same file the Python harness uses.
`src/labels.ts` is generated from it with `npm run labels`, and `scripts/lib/test_e2e_labels_ts.py` fails when the two drift.
Change a label in the Python file, then regenerate.

## Add a test

1. Pick or create a spec in `src/tests/`. One behavior per `test`, named for what a person sees.
2. Take the `signedIn` fixture for two signed-in users, or `users` to drive sign-in yourself.
3. Wrap each user-visible step in `step('...', ...)` from `../fixtures`, so the report reads as a story. It also waits for the screen to be painted and holds it briefly, because the accessibility tree can be ahead of what the video records.
4. Assert on what the user sees, scoped to the surface that proves it (a call tile, not a name that the member list also shows), not on sleeps. If something is flaky, fix the wait.
5. Give messages unique text with `uniqueText`, since specs share one deployment.

```ts
import { step, test } from '../fixtures';
import { openChannel, send, uniqueText } from '../messages';

test('bob sees what alice sends', async ({ signedIn }) => {
  const { alice, bob } = signedIn;
  const text = uniqueText('hello');
  await step('both open #general', async () => {
    await openChannel(alice, 'general');
    await openChannel(bob, 'general');
  });
  await step('alice sends it', () => send(alice, text));
  await step('bob sees it', () => bob.see(text));
});
```

If the control you need has no accessible name, add one in the app and then to `e2e_labels.py`.
Do not reach for a coordinate.
