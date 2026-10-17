// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, type Locator } from '@playwright/test';
import type { FlutterApp } from './flutter';
import { L } from './labels';

/** A message text unique to one test run, so specs sharing a channel never see each other's. */
export function uniqueText(prefix: string): string {
  return `${prefix} ${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

export async function openChannel(app: FlutterApp, channel: string): Promise<void> {
  await app.click(channel);
  await app.seeField(L.COMPOSER);
}

export async function send(app: FlutterApp, text: string): Promise<void> {
  await app.type(L.COMPOSER, text);
  await app.click(L.SEND);
}

/** The message row, which is the tappable node whose text is the message itself. */
export function messageRow(app: FlutterApp, text: string): Locator {
  return app.page.locator(`flt-semantics[flt-tappable]:not(:has(flt-semantics[flt-tappable]))`).filter({ hasText: text });
}

/** Waits until the message has left the optimistic "Sending" state, so it has a server id to act on. */
export async function expectSent(app: FlutterApp, text: string): Promise<void> {
  await app.see(text);
  await expect(app.page.locator('flt-semantics').filter({ hasText: new RegExp(String.raw`Sending\s*${text}`) })).toHaveCount(0);
}

/** The message's box once the list has stopped moving under it, so a pointer lands where the row is. */
async function settledBox(app: FlutterApp, row: Locator): Promise<{ x: number; y: number; width: number; height: number }> {
  let box = null as Awaited<ReturnType<Locator['boundingBox']>>;
  await expect(async () => {
    box = await row.boundingBox();
    await app.flutterFrames(6);
    expect(await row.boundingBox()).toEqual(box);
    expect(box).not.toBeNull();
  }).toPass({ timeout: 10_000 });
  return box!;
}

/**
 * Hovers a message and presses one of the buttons its toolbar then shows.
 *
 * The toolbar belongs to whichever row is under the pointer, and rows move as
 * messages arrive, so the button is only pressed when it sits on the target row.
 */
export async function toolbar(app: FlutterApp, text: string, action: string): Promise<void> {
  await expect(async () => {
    const row = app.text(text).first();
    await row.waitFor({ state: 'attached' });
    const box = await settledBox(app, row);
    await app.page.mouse.move(box.x + Math.min(box.width / 2, 120), box.y + box.height / 2);
    const button = await app.control(action, { timeout: 2_000 });
    const at = await button.boundingBox();
    expect(at, `the ${action} button should be on screen`).not.toBeNull();
    expect(at!.y).toBeGreaterThanOrEqual(box.y - 40);
    expect(at!.y).toBeLessThanOrEqual(box.y + box.height);
    await button.evaluate((el) => (el as HTMLElement).click());
  }).toPass({ timeout: 20_000 });
}

/**
 * The reaction chips on a message, as their text ("emoji count").
 *
 * A message with reactions becomes one group named "time, text" whose children
 * are the chips, so the chips are the buttons inside the group named by the text.
 */
export async function reactionsOn(app: FlutterApp, text: string): Promise<string[]> {
  return app.page.evaluate((needle) => {
    const row = [...document.querySelectorAll('flt-semantics[aria-label]')].find((n) =>
      (n.getAttribute('aria-label') ?? '').trim().endsWith(needle),
    );
    const chip = /^[^\p{L}\s]+\s+\d+$/u;
    // A chip is a button wrapping a button, so only the innermost counts.
    return [...(row?.querySelectorAll('flt-semantics[role="button"]') ?? [])]
      .filter((n) => !n.querySelector('flt-semantics[role="button"]'))
      .map((n) => (n.textContent ?? '').trim())
      .filter((label) => chip.test(label))
      .map((label) => label.replace(/\s+/g, ' '));
  }, text);
}
