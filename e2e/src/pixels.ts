// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import type { Page } from '@playwright/test';
import { inflateSync } from 'node:zlib';

export interface Rgb {
  r: number;
  g: number;
  b: number;
}

/** The colour of one pixel of what is on screen, read from a 1x1 screenshot of it. */
export async function pixelAt(page: Page, x: number, y: number): Promise<Rgb> {
  const png = await page.screenshot({ clip: { x, y, width: 1, height: 1 } });
  const chunks: Buffer[] = [];
  for (let at = 8; at < png.length; ) {
    const length = png.readUInt32BE(at);
    if (png.toString('ascii', at + 4, at + 8) === 'IDAT') chunks.push(png.subarray(at + 8, at + 8 + length));
    at += 12 + length;
  }
  // One row, so its filter byte is the first byte and the filter is a no-op for the first pixel.
  const row = inflateSync(Buffer.concat(chunks));
  return { r: row[1], g: row[2], b: row[3] };
}

export function luminance({ r, g, b }: Rgb): number {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
