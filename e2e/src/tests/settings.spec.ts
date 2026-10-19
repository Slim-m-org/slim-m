// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, test, step } from '../fixtures';
import { L } from '../labels';
import { luminance, pixelAt } from '../pixels';

// A point in the message pane that is plain background in both themes.
const BACKDROP = { x: 640, y: 200 };

test('switching to the dark theme in Settings repaints the app and is remembered', async ({ signedIn }) => {
  const { alice } = signedIn;

  await step('the app starts light', async () => {
    await alice.see(L.PERSONAL_SETTINGS);
    expect(luminance(await pixelAt(alice.page, BACKDROP.x, BACKDROP.y))).toBeGreaterThan(200);
  });
  await step('alice opens personal settings, then Appearance', async () => {
    await alice.click(L.PERSONAL_SETTINGS);
    await alice.click(L.APPEARANCE_PANE);
    await alice.see(L.THEME_DARK);
  });
  await step('she picks Dark', async () => {
    await alice.click(L.THEME_DARK);
  });
  await step('Dark is the selected option and the background goes dark', async () => {
    await expect(alice.page.locator('flt-semantics[aria-current="true"]').filter({ hasText: /^\s*Dark\s*$/ })).toBeAttached();
    await expect.poll(async () => luminance(await pixelAt(alice.page, BACKDROP.x, BACKDROP.y))).toBeLessThan(80);
  });
  await step('the choice was written to storage, so it survives a reload', async () => {
    // Theme is kept per Space, under 'flutter.slimm.space.<origin>.slimm.appearance.theme'.
    const stored = await alice.page.evaluate(() => {
      const key = Object.keys(localStorage).find((k) => k.startsWith('flutter.') && k.endsWith('slimm.appearance.theme'));
      return key ? JSON.parse(localStorage.getItem(key) ?? 'null') : null;
    });
    expect(stored).toBe('dark');
  });
});
