// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ChannelCategorySections` used to `ref.watch(voiceControllerProvider)` at
/// its own top level and hand the result down to every row it built, text
/// channels included. `voiceControllerProvider` updates on essentially every
/// room event (active speaker, mute, connection quality), so during a call
/// every text-channel row in the rail rebuilt on every one of those, when
/// before the categories merge only the voice section ever watched it.
///
/// `VoiceChannelRow` itself has since split that watch further: `state` and
/// `channelId` come from `voiceFlagsProvider` (a `.select` down to the two
/// fields the row's own `inCall` check needs), and the roster comes from
/// `voiceParticipantsProvider`, watched only for the one row actually in a
/// call. Both still trace back to `voiceControllerProvider`, so the scoping
/// property this file guards - the sections file must never watch it, only
/// the row may - is unchanged; only the row's own watch got narrower.
///
/// A behavioural test would have to distinguish "rebuilt" from "rebuilt and
/// happened to render the same pixels", which nothing in `flutter_test`
/// exposes without instrumenting the widgets themselves. Reading the source
/// is what `route_reachability_test.dart` already does for the same shape of
/// reason: this is a scoping property of which widget owns a `ref.watch`,
/// not a rendered outcome a pixel-level assertion could see.
///
/// Both files are read through `support/code_only.dart` before either
/// `contains` check runs: the "must appear" half is the vulnerable one,
/// and reproduced directly - removing the real `ref.watch(...)` call and
/// leaving `// used to be ref.watch(voiceControllerProvider) before a
/// refactor` in its place still passed, since a bare substring search
/// cannot tell a comment's prose from real code.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/code_only.dart';

void main() {
  test(
    'ChannelCategorySections does not watch voiceControllerProvider itself',
    () {
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason: 'run this from the app package root',
      );

      final source = codeOnly(
        File(
          'lib/src/features/channels/widgets/channel_rail_sections.dart',
        ).readAsStringSync(),
      );
      expect(
        source.contains('voiceControllerProvider') ||
            source.contains('voiceFlagsProvider') ||
            source.contains('voiceParticipantsProvider'),
        isFalse,
        reason:
            'watching any slice of the voice controller here rebuilds every '
            'row in every category - text channels included - on every room '
            'event; only VoiceChannelRow itself should watch it',
      );
    },
  );

  test(
    'VoiceChannelRow watches voiceFlagsProvider and voiceParticipantsProvider '
    'itself',
    () {
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason: 'run this from the app package root',
      );

      final source = codeOnly(
        File(
          'lib/src/features/channels/widgets/channel_rail_channel_rows.dart',
        ).readAsStringSync(),
      );
      expect(
        RegExp(r'ref\.watch\(\s*voiceFlagsProvider').hasMatch(source),
        isTrue,
        reason:
            'the row itself must be the one thing that reacts to a room '
            'event, so a rebuild stays scoped to the voice rows on screen '
            'rather than the whole rail',
      );
      expect(
        source.contains('voiceParticipantsProvider'),
        isTrue,
        reason:
            'the roster for the row actually in a call comes from the '
            'participants provider directly, not through the full state',
      );
    },
  );
}
