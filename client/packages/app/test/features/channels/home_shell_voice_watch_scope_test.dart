// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `HomeShell.build` used to `ref.watch(voiceControllerProvider)` whole, at
/// its own top level, only to read `state` and `channelId` when deciding
/// whether a call running in some other channel needs its own strip in the
/// compact layout. `voiceControllerProvider` updates on essentially every
/// room event (active speaker, mute, connection quality), so during a call
/// the entire shell rebuilt on every one of those, when the strip decision
/// only ever turns on the call's connection state or which channel it is in.
///
/// The fix is the same `.select` scoping `ChannelCategorySections` got in
/// `channel_rail_voice_watch_scope_test.dart`: the shell now watches a
/// `(state, channelId)` record, so a Dart record's structural equality holds
/// the rebuild until one of those two changes and drops the participant and
/// speaker churn entirely.
///
/// A behavioural test would have to distinguish "rebuilt" from "rebuilt and
/// happened to render the same pixels", which nothing in `flutter_test`
/// exposes without instrumenting the widgets themselves. This is a scoping
/// property of which slice a `ref.watch` owns, not a rendered outcome, so it
/// is read from source the way that sibling test and `route_reachability_test`
/// already do. The source is scrubbed through `codeOnly` (`slimm_test_support`) first,
/// so a bare-watch left behind in a comment cannot pass the check: the
/// "must be absent" half is the vulnerable one and is reproduced directly.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slimm_test_support/source_gates.dart';

void main() {
  String homeShellSource() {
    final lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run this from the app package root',
    );
    return codeOnly(File('lib/src/screens/home_shell.dart').readAsStringSync());
  }

  test(
    'HomeShell narrows its voice watch to a select, never the whole state',
    () {
      expect(
        homeShellSource().contains('ref.watch(voiceControllerProvider)'),
        isFalse,
        reason:
            'watching the voice controller whole here rebuilds the entire '
            'compact shell on every room event during a call; the strip '
            'decision only reads state and channelId',
      );
    },
  );

  test('HomeShell still watches the two fields the strip decision needs', () {
    expect(
      homeShellSource().contains('voiceControllerProvider.select'),
      isTrue,
      reason:
          'the shell must still react to the call starting, ending or moving '
          'channel, just not to participant and speaker churn',
    );
  });
}
