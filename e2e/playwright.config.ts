// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { defineConfig } from '@playwright/test';
import { workDir } from './src/stack';

const MINUTE = 60_000;

// CI keeps video, trace and a screenshot of every test; a local run that only wants the answer can
// keep them for failures (E2E_EVIDENCE=failure) or drop them (off), which cuts encoding time a lot.
const evidence = process.env.E2E_EVIDENCE ?? 'on';
const keep = ({ on: 'on', failure: 'retain-on-failure', off: 'off' } as const)[
  evidence as 'on' | 'failure' | 'off'
] ?? 'on';
// Parallel shards must not write over each other's results and report.
const outRoot = process.env.E2E_PW_OUT ?? '.';

export default defineConfig({
  testDir: './src/tests',
  outputDir: `${outRoot}/test-results`,
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
  reporter: [['html', { open: 'never', outputFolder: `${outRoot}/playwright-report` }], ['list']],
  use: {
    video: keep,
    trace: keep,
    screenshot: keep === 'retain-on-failure' ? 'only-on-failure' : keep,
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
