// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { test as base, type Browser, type BrowserContextOptions, type TestInfo } from '@playwright/test';
import { FlutterApp } from './flutter';
import { L } from './labels';
import { readStack, type Stack } from './stack';

export type UserName = 'alice' | 'bob';
export const USERS: UserName[] = ['alice', 'bob'];

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
  const app = new FlutterApp(await context.newPage(), name);
  await app.open(stack.web);
  return app;
}

async function openBoth(browser: Browser, stack: Stack, testInfo: TestInfo, sessions?: Record<UserName, StorageState>): Promise<Users> {
  const [alice, bob] = await Promise.all(USERS.map((name) => openUser(browser, name, stack, testInfo, sessions?.[name])));
  return { alice, bob };
}

/** Closes the user's context, which finalises their video, and attaches the video. */
async function closeBoth(users: Users, testInfo: TestInfo): Promise<void> {
  await Promise.all(
    Object.values(users).map(async (app) => {
      const { page } = app;
      await page.context().close();
      const video = page.video();
      if (video) await testInfo.attach(`${app.name}.webm`, { path: await video.path(), contentType: 'video/webm' });
    }),
  );
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
