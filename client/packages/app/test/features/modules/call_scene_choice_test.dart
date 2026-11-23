// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call scene the viewer closed stays closed for that call only: the next
/// call in the same channel shows scenes again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/providers/call_scene_choice.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

void main() {
  test('closing a scene does not carry into the next call', () {
    final inChannel = StateProvider<String?>((ref) => 'c1');
    final container = ProviderContainer(
      overrides: [
        voiceFlagsProvider.overrideWith(
          (ref) => VoiceFlags(channelId: ref.watch(inChannel)),
        ),
      ],
    );
    addTearDown(container.dispose);
    final choice = container.listen(callSceneChoiceProvider('c1'), (_, _) {});
    addTearDown(choice.close);

    container.read(callSceneChoiceProvider('c1').notifier).close('noughts');
    expect(choice.read().closed, {'noughts'});

    container.read(inChannel.notifier).state = null;
    container.read(voiceFlagsProvider);
    container.read(inChannel.notifier).state = 'c1';
    container.read(voiceFlagsProvider);

    expect(choice.read().closed, isEmpty);
  });

  test('another channel\'s call ending leaves the choice alone', () {
    final inChannel = StateProvider<String?>((ref) => 'c2');
    final container = ProviderContainer(
      overrides: [
        voiceFlagsProvider.overrideWith(
          (ref) => VoiceFlags(channelId: ref.watch(inChannel)),
        ),
      ],
    );
    addTearDown(container.dispose);
    final choice = container.listen(callSceneChoiceProvider('c1'), (_, _) {});
    addTearDown(choice.close);

    container.read(callSceneChoiceProvider('c1').notifier).close('noughts');
    container.read(inChannel.notifier).state = null;
    container.read(voiceFlagsProvider);

    expect(choice.read().closed, {'noughts'});
  });
}
