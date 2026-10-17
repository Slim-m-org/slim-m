// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { expect, test } from '../fixtures';
import { L } from '../labels';
import { sfuParticipants } from '../livekit';

test('both joining the voice channel see each other in the call', async ({ signedIn, stack }) => {
  const { alice, bob } = signedIn;

  await test.step('alice joins the voice channel by clicking it', async () => {
    await alice.click(L.VOICE_CHANNEL);
    await alice.see(L.IN_CALL);
  });
  await test.step('bob joins the same channel', async () => {
    await bob.click(L.VOICE_CHANNEL);
    await bob.see(L.IN_CALL);
  });
  await test.step('each of them reports two people in the call', async () => {
    await alice.see('2 in call');
    await bob.see('2 in call');
  });
  await test.step('each sees the other by name', async () => {
    await alice.see('Bob');
    await bob.see('Alice');
  });
  await test.step('the SFU agrees: two participants, each publishing a live microphone', async () => {
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
  await test.step('both leave the call', async () => {
    await alice.click(L.LEAVE_CALL);
    await bob.click(L.LEAVE_CALL);
    await alice.seeNo('2 in call');
  });
});
