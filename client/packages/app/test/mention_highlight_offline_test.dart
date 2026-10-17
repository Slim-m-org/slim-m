// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mention stays highlighted when the member fetch stops answering.
///
/// The transcript decides whether `@someone` is a real mention by looking the
/// name up in the member roster, which is a network fetch. Reading that with
/// `maybeWhen(data:)` treats a failed fetch as an empty deployment, so every
/// mention in view quietly became plain text the moment the connection
/// dropped - reported 2026-08-13, "mentions also get unhighlighted when the
/// server was offline".
///
/// `AsyncValue` keeps whatever resolved before an error, so the roster is
/// still there to be read: `valueOrNull` sees it and `maybeWhen(data:)` does
/// not, because an `AsyncError` carrying a previous value is still an
/// `AsyncError`. The second test below pins that difference, since it is the
/// whole reason the first one can pass at all.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';

api.UserProfile _member(String username) => api.UserProfile(
  id: username,
  username: username,
  displayName: username,
  createdAt: 0,
);

void main() {
  test('a roster that failed to refresh still names its members', () {
    final loaded = AsyncData<List<api.UserProfile>>([
      _member('Ada'),
      _member('grace'),
    ]);
    final offline = AsyncError<List<api.UserProfile>>(
      Exception('offline'),
      StackTrace.empty,
    ).copyWithPrevious(loaded);

    expect(knownUsernamesFrom(loaded), {'ada', 'grace'});
    expect(
      knownUsernamesFrom(offline),
      {'ada', 'grace'},
      reason:
          'a failed refresh is not evidence the deployment has no members, '
          'and treating it that way unhighlights every mention on screen',
    );
  });

  test('a roster that never resolved names nobody', () {
    expect(
      knownUsernamesFrom(const AsyncLoading<List<api.UserProfile>>()),
      isEmpty,
      reason:
          'a cold start with no connection has genuinely never been told who '
          'the members are',
    );
  });

  test('maybeWhen(data:) is what could not see a retained roster', () {
    final offline = AsyncError<List<api.UserProfile>>(
      Exception('offline'),
      StackTrace.empty,
    ).copyWithPrevious(AsyncData<List<api.UserProfile>>([_member('ada')]));

    expect(
      offline.maybeWhen(
        data: (v) => v,
        orElse: () => const <api.UserProfile>[],
      ),
      isEmpty,
      reason: 'the reading this fix replaced, kept here so the why survives',
    );
  });
}
