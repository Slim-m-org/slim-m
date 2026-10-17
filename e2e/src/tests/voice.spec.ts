// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, test, step } from '../fixtures';
import { callCount, join, tile } from '../call';
import { L } from '../labels';
import { sfuParticipants } from '../livekit';

test('both joining the voice channel see each other in the call', async ({ signedIn, stack }) => {
  const { alice, bob } = signedIn;

  await step('alice joins the voice channel by clicking it and is alone in the call', async () => {
    await join(alice, L.VOICE_CHANNEL, 'Alice');
    await expect(callCount(alice, 1)).toBeAttached();
  });
  await step('bob joins the same channel', () => join(bob, L.VOICE_CHANNEL, 'Bob'));
  await step('each of them reports two people in the call', async () => {
    await expect(callCount(alice, 2)).toBeAttached();
    await expect(callCount(bob, 2)).toBeAttached();
  });
  await step('each sees the other in a participant tile, and not just in the member list', async () => {
    await expect(tile(alice, 'Bob')).toBeAttached();
    await expect(tile(bob, 'Alice')).toBeAttached();
  });
  await step('the SFU agrees: two participants, each publishing a live microphone', async () => {
    await expect
      .poll(
        async () => {
          const parts = await sfuParticipants(stack, stack.voiceRoom);
          return parts.length === 2 && parts.every((p) => p.state === 'ACTIVE' && p.tracks?.some((t) => t.source === 'MICROPHONE' && !t.muted));
        },
        { timeout: 30_000, message: 'both participants should publish an unmuted microphone' },
      )
      .toBe(true);
  });
  await step('both leave the call', async () => {
    await bob.click(L.LEAVE_CALL);
    await alice.click(L.LEAVE_CALL);
    await expect(tile(alice, 'Alice')).toHaveCount(0);
    await expect(tile(bob, 'Bob')).toHaveCount(0);
  });
});
