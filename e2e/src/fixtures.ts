// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { test as base, type Browser, type BrowserContextOptions, type TestInfo } from '@playwright/test';
import { FlutterApp } from './flutter';
import { L } from './labels';
import { readStack, type Stack } from './stack';

export type UserName = 'alice' | 'bob';
export const USERS: UserName[] = ['alice', 'bob'];

const appsByTest = new WeakMap<TestInfo, FlutterApp[]>();

/** How long each step's end state stays on screen, so a person watching the video can read it. */
const LINGER_MS = Number(process.env.E2E_LINGER_MS ?? 700);

type StorageState = NonNullable<BrowserContextOptions['storageState']>;

export interface Users {
  alice: FlutterApp;
  bob: FlutterApp;
}

interface WorkerFixtures {
  stack: Stack;
  /** Each user's session after one real sign-in, since the server rate-limits password sign-ins. */
  sessions: Record<UserName, StorageState>;
}

interface TestFixtures {
  /** Both users in their own browser context (and so their own video), not yet signed in. */
  users: Users;
  /** Both users with their session restored and looking at the channel list. */
  signedIn: Users;
}

async function openUser(
  browser: Browser,
  name: UserName,
  stack: Stack,
  testInfo: TestInfo,
  storageState?: StorageState,
): Promise<FlutterApp> {
  // Recorded here because a context made by hand is not covered by the config's video option.
  const context = await browser.newContext({
    permissions: ['microphone', 'camera'],
    baseURL: stack.web,
    storageState,
    recordVideo: { dir: testInfo.outputPath(`video-${name}`), size: { width: 1280, height: 900 } },
  });
  const page = await context.newPage();
  // The video starts with the page, so this lets a reviewer line a step up with a video timestamp.
  testInfo.annotations.push({ type: `video-start-${name}`, description: String(Date.now()) });
  const app = new FlutterApp(page, name);
  appsByTest.set(testInfo, [...(appsByTest.get(testInfo) ?? []), app]);
  await app.open(stack.web);
  return app;
}

async function openBoth(browser: Browser, stack: Stack, testInfo: TestInfo, sessions?: Record<UserName, StorageState>): Promise<Users> {
  const [alice, bob] = await Promise.all(USERS.map((name) => openUser(browser, name, stack, testInfo, sessions?.[name])));
  return { alice, bob };
}

/** Closes the user's context, which finalises their video, and attaches the video. */
async function closeBoth(users: Users, testInfo: TestInfo): Promise<void> {
  await settleVideo();
  await Promise.all(
    Object.values(users).map(async (app) => {
      const { page } = app;
      await page.context().close();
      const video = page.video();
      if (video) await testInfo.attach(`${app.name}.webm`, { path: await video.path(), contentType: 'video/webm' });
    }),
  );
}

/**
 * A test.step whose end state is painted and held on screen for every user in the test.
 *
 * The pause is pacing for the video, not synchronisation: the step has already asserted its outcome.
 */
export async function step<T>(title: string, body: () => Promise<T> | T): Promise<T> {
  return test.step(title, async () => {
    const result = await body();
    await settleVideo(title);
    return result;
  });
}

async function settleVideo(title = 'end of test'): Promise<void> {
  const info = test.info();
  const apps = appsByTest.get(info) ?? [];
  await Promise.all(apps.map((app) => app.painted().catch(() => undefined)));
  // Lets a reviewer pull the frame for this step out of each video by timestamp.
  info.annotations.push({ type: 'step-end', description: JSON.stringify({ title, at: Date.now() }) });
  if (apps.length) await apps[0].page.waitForTimeout(LINGER_MS);
}

export async function signIn(app: FlutterApp, stack: Stack, username: UserName): Promise<void> {
  await app.click('Connect to a Space');
  await app.type('Server address', stack.api);
  await app.click('Continue');
  await app.click('It matches');
  await app.type('Username', username);
  await app.type('Password', stack.secret);
  await app.click('Sign in');
  await app.waitForUrl('#/channels');
  // Setup opens only on an account's first sign-in, so a later worker's browser goes straight to the shell.
  const skip = await app.control(L.SKIP_SETUP, { timeout: 10_000 }).catch(() => undefined);
  if (skip) {
    await skip.evaluate((el) => (el as HTMLElement).click());
    return;
  }
  // No Skip button means the shell is already up; if it is not, setup is stuck and this says so here.
  await app.see(`${username === 'alice' ? 'Alice' : 'Bob'}, online`);
}

export const test = base.extend<TestFixtures, WorkerFixtures>({
  stack: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      await use(readStack());
    },
    { scope: 'worker' },
  ],

  sessions: [
    async ({ browser, stack }, use) => {
      const sessions = {} as Record<UserName, StorageState>;
      for (const name of USERS) {
        const context = await browser.newContext({ baseURL: stack.web });
        const app = new FlutterApp(await context.newPage(), name);
        await app.open(stack.web);
        await signIn(app, stack, name);
        await app.see(name === 'alice' ? 'Alice, online' : 'Bob, online');
        sessions[name] = await context.storageState({ indexedDB: true });
        await context.close();
      }
      await use(sessions);
    },
    { scope: 'worker' },
  ],

  users: async ({ browser, stack }, use, testInfo) => {
    const users = await openBoth(browser, stack, testInfo);
    await use(users);
    await closeBoth(users, testInfo);
  },

  signedIn: async ({ browser, stack, sessions }, use, testInfo) => {
    const users = await openBoth(browser, stack, testInfo, sessions);
    await test.step('alice and bob open the app with their sessions', async () => {
      await Promise.all(Object.values(users).map((app) => app.see(L.TEXT_CHANNEL)));
    });
    await use(users);
    await closeBoth(users, testInfo);
  },
});

export { expect } from '@playwright/test';
