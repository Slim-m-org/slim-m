// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web client's `/join?server=&code=` arrival from the invite landing page.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/invite_pending.dart';

void main() {
  final probe = Provider.family<String?, Uri>(claimWebInvite);

  test('a join url with an invite is claimed and redirected clean', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final next = container.read(
      probe(Uri.parse('/join?server=https%3A%2F%2Fchat.example&code=abc234')),
    );
    await Future<void>.value();

    expect(next, '/join');
    final claimed = container.read(tappedInviteProvider);
    expect(claimed!.code, 'abc234');
    expect(claimed.server, Uri.parse('https://chat.example'));
  });

  test('a bare join url or another path is left alone', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(probe(Uri.parse('/join'))), isNull);
    expect(
      container.read(probe(Uri.parse('/sign-in?server=https://a.b&code=x'))),
      isNull,
    );
    await Future<void>.value();
    expect(container.read(tappedInviteProvider), isNull);
  });
}
