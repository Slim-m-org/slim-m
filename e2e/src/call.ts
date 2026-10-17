// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, type Locator } from '@playwright/test';
import type { FlutterApp } from './flutter';
import { L } from './labels';

/**
 * A participant's tile in the call surface, named "Bob, microphone on, ..." and "Alice, you, ...".
 *
 * The rail and the member list also name people ("Bob, online", "Bob, speaking"), so a
 * tile is matched by the microphone state only a call tile carries.
 */
export function tile(app: FlutterApp, name: string): Locator {
  return app.page.locator('flt-semantics[role="button"]').filter({ hasText: new RegExp(String.raw`^\s*${name}, (you, )?microphone`, 'i') });
}

/** The call header's count, which is the only node that reads exactly "N in call". */
export function callCount(app: FlutterApp, count: number): Locator {
  return app.exact(`${count} in call`);
}

/** Clicks the voice channel and waits until this user's own tile and the call controls are up. */
export async function join(app: FlutterApp, channel: string, self: string): Promise<void> {
  await app.click(channel);
  await expect(app.exact(L.LEAVE_CALL).or(app.page.locator('flt-semantics[role="button"]').filter({ hasText: /^\s*Leave call/ })).first()).toBeAttached();
  await expect(tile(app, self)).toBeAttached();
}
