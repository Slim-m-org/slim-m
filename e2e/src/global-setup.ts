// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { assertLocalStack, readStack, stackScript } from './stack';

export default async function globalSetup(): Promise<void> {
  if (process.env.E2E_STACK_UP !== '1') stackScript('up');
  assertLocalStack();
  await completeAdminSetup();
}

/** alice claimed the deployment, so the admin setup would otherwise cover every test's screen. */
async function completeAdminSetup(): Promise<void> {
  const stack = readStack();
  const login = await fetch(`${stack.api}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'alice', password: stack.secret, device_name: 'e2e-admin' }),
  });
  if (!login.ok) throw new Error(`admin sign-in for setup failed: ${login.status}`);
  const { access_token: token } = (await login.json()) as { access_token: string };
  const done = await fetch(`${stack.api}/space/setup/complete`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!done.ok) throw new Error(`completing admin setup failed: ${done.status}`);
}
