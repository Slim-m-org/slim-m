// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export interface Stack {
  api: string;
  web: string;
  voiceRoom: string;
  voiceChannelName: string;
  secret: string;
  wav: string;
  fixtures: string;
  livekit: { http: string; key: string; secret: string };
}

export const repoRoot = path.resolve(__dirname, '..', '..');

export function workDir(): string {
  return process.env.E2E_WORK ?? path.join(repoRoot, 'e2e', '.work');
}

export function stackFile(): string {
  return path.join(workDir(), 'stack.json');
}

export function stackScript(action: 'up' | 'down'): void {
  execFileSync('bash', [path.join(repoRoot, 'scripts', 'e2e-stack.sh'), action], {
    stdio: 'inherit',
    env: { ...process.env, E2E_WORK: workDir() },
  });
}

// Refuses anything that is not a local throwaway stack; see scripts/lib/e2e_stack_guard.py.
export function assertLocalStack(): void {
  execFileSync('python3', [path.join(repoRoot, 'scripts', 'lib', 'e2e_stack_guard.py'), stackFile()], {
    stdio: 'inherit',
    cwd: path.join(repoRoot, 'scripts', 'lib'),
  });
}

/** The stack as the boot script wrote it: plain http, for the suite's own calls to the server. */
export function readRawStack(): Stack {
  return JSON.parse(readFileSync(stackFile(), 'utf8')) as Stack;
}

/** The stack as a browser reaches it: web build and server behind the one https origin once the front is up. */
export function readStack(): Stack {
  const stack = readRawStack();
  const originFile = path.join(workDir(), 'secure-origin.txt');
  if (!existsSync(originFile)) return stack;
  const origin = readFileSync(originFile, 'utf8').trim();
  return { ...stack, api: origin, web: origin };
}
