// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { stopSecureFront } from './secure-front';
import { stackScript } from './stack';

export default async function globalTeardown(): Promise<void> {
  await stopSecureFront();
  if (process.env.E2E_KEEP === '1') return;
  stackScript('down');
}
