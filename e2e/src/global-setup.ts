// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { assertLocalStack, stackScript } from './stack';

export default function globalSetup(): void {
  if (process.env.E2E_STACK_UP !== '1') stackScript('up');
  assertLocalStack();
}
