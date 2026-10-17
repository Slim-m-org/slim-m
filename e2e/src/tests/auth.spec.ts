// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, signIn, test } from '../fixtures';

test.describe('signing in', () => {
  test('alice and bob each sign in with their own account', async ({ users, stack }) => {
    for (const [name, app] of Object.entries(users)) {
      await test.step(`${name} signs in through the Space connect flow`, async () => {
        await signIn(app, stack, name as 'alice' | 'bob');
      });
      await test.step(`${name} lands on the channel list with the seeded channels`, async () => {
        await app.see('general');
        await app.see('lounge');
        await app.see(`${name}, online`);
      });
      expect(app.page.url()).toContain('#/channels');
    }
  });
});
