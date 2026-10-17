// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { createHmac } from 'node:crypto';
import type { Stack } from './stack';

export interface SfuParticipant {
  identity: string;
  state: string;
  tracks?: { source: string; muted?: boolean }[];
}

function base64url(data: Buffer | string): string {
  return Buffer.from(data).toString('base64url');
}

/** Asks the SFU itself who is in a room, so a roster on screen is checked against the media server. */
export async function sfuParticipants(stack: Stack, room: string): Promise<SfuParticipant[]> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = base64url(
    JSON.stringify({ iss: stack.livekit.key, sub: 'e2e', nbf: now - 30, exp: now + 300, video: { roomAdmin: true, room } }),
  );
  const signature = createHmac('sha256', stack.livekit.secret).update(`${header}.${payload}`).digest('base64url');
  const response = await fetch(`${stack.livekit.http}/twirp/livekit.RoomService/ListParticipants`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${header}.${payload}.${signature}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ room }),
  });
  if (!response.ok) throw new Error(`the SFU answered ${response.status}`);
  const body = (await response.json()) as { participants?: SfuParticipant[] };
  return body.participants ?? [];
}
