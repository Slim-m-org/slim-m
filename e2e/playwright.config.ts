// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { defineConfig } from '@playwright/test';
import { workDir } from './src/stack';

const MINUTE = 60_000;

export default defineConfig({
  testDir: './src/tests',
  outputDir: 'test-results',
  // One stack is shared, and the specs run in order against its single set of accounts.
  workers: 1,
  fullyParallel: false,
  retries: 0,
  // A cold stack builds the server and the Flutter web client before the first test.
  globalTimeout: 90 * MINUTE,
  timeout: 4 * MINUTE,
  expect: { timeout: 30_000 },
  globalSetup: './src/global-setup.ts',
  globalTeardown: './src/global-teardown.ts',
  reporter: [['html', { open: 'never' }], ['list']],
  use: {
    video: 'on',
    trace: 'on',
    screenshot: 'on',
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
    viewport: { width: 1280, height: 900 },
    launchOptions: {
      args: [
        '--use-fake-device-for-media-stream',
        '--use-fake-ui-for-media-stream',
        `--use-file-for-fake-audio-capture=${workDir()}/fake-voice.wav`,
        '--autoplay-policy=no-user-gesture-required',
        '--enable-unsafe-swiftshader',
        '--mute-audio',
        "--auto-select-desktop-capture-source=Entire screen",
      ],
    },
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
