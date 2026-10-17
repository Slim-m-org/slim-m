// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { stackScript } from './stack';

export default function globalTeardown(): void {
  if (process.env.E2E_KEEP === '1') return;
  stackScript('down');
}
