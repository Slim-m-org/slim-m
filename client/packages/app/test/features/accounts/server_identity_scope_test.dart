// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row that goes from naming one server to naming another lets go of the
/// first server's container: a scope re-pointed at a new container stays
/// registered with the old one, which then hands it work it never runs.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_server_label.dart';
import 'package:slimm_app/src/providers/server_info.dart';

final _disposed = <String>[];

final _row = Provider.autoDispose.family<String, String>((ref, id) {
  ref.onDispose(() => _disposed.add(id));
  return id;
});

AccountEntry _entry(String name) {
  final container = ProviderContainer(
    overrides: [
      serverInfoProvider.overrideWith(
        (ref) async => api.Version(
          name: 'slim-m',
          version: '1',
          protocol: 1,
          spaceName: name,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return AccountEntry(
    account: Account.forServer(Uri.parse('https://$name.example')),
    container: container,
    active: false,
    signedIn: true,
    unread: AccountUnread.none,
    inCall: false,
  );
}

/// The root's own scope for each container, as `AccountRoot` keeps, with [row] beside them.
Widget _app(List<AccountEntry> entries, Widget row) => Column(
  textDirection: TextDirection.ltr,
  children: [
    for (final entry in entries)
      UncontrolledProviderScope(
        key: ObjectKey(entry.container),
        container: entry.container,
        child: const SizedBox.shrink(),
      ),
    row,
  ],
);

Widget _naming(AccountEntry entry) => ServerIdentityScope(
  entry: entry,
  builder: (context, name, _) => Text(name, textDirection: TextDirection.ltr),
);

void main() {
  setUp(_disposed.clear);

  testWidgets('a row that moved on to another server leaves the first one '
      'scheduling as before', (tester) async {
    final first = _entry('first');
    final second = _entry('second');
    final both = [first, second];
    await tester.pumpWidget(_app(both, _naming(first)));
    await tester.pump();
    await tester.pumpWidget(_app(both, _naming(second)));
    await tester.pump();
    await tester.pumpWidget(_app(both, const SizedBox.shrink()));
    await tester.pump();

    // Twice: the first queue reaches a scope left registered, the second finds it still holding the first.
    for (final id in ['late', 'later']) {
      first.container.listen<String>(_row(id), (_, _) {}).close();
      await tester.pump();
      await tester.pump();
    }

    expect(_disposed, containsAll(['late', 'later']));
    await tester.pumpWidget(const SizedBox());
  });
}
