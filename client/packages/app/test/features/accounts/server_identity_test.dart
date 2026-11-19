// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row that goes from naming one server to naming another lets go of the
/// first server's container, which keeps disposing and refreshing as before.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_server_label.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/widgets/space_icon.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/synthetic_png.dart';

final _disposed = <String>[];

final _row = Provider.autoDispose.family<String, String>((ref, id) {
  ref.onDispose(() => _disposed.add(id));
  return id;
});

/// The name a container's server answers with; null until a test renames it.
final _renamed = StateProvider<String?>((ref) => null);

final _iconFetches = <String>[];

AccountEntry _entry(String name, {int? iconUpdatedAt}) {
  final container = ProviderContainer(
    overrides: [
      serverInfoProvider.overrideWith(
        (ref) async => api.Version(
          name: 'slim-m',
          version: '1',
          protocol: 1,
          spaceName: ref.watch(_renamed) ?? name,
          iconUpdatedAt: iconUpdatedAt,
        ),
      ),
      spaceIconBytesProvider.overrideWith((ref, at) async {
        _iconFetches.add(name);
        return solidPng(4, 4);
      }),
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

/// The root's own scope for each container, as `AccountRoot` keeps, after [row] as it puts them.
Widget _app(List<AccountEntry> entries, Widget row) => Column(
  textDirection: TextDirection.ltr,
  children: [
    row,
    for (final entry in entries)
      UncontrolledProviderScope(
        key: ObjectKey(entry.container),
        container: entry.container,
        child: const SizedBox.shrink(),
      ),
  ],
);

Widget _naming(AccountEntry entry) => ServerIdentity(
  entry: entry,
  builder: (context, name, _) => Text(name, textDirection: TextDirection.ltr),
);

void main() {
  setUp(() {
    _disposed.clear();
    _iconFetches.clear();
  });

  testWidgets('a row that moved on to another server leaves the first one '
      'scheduling as before', (tester) async {
    final first = _entry('first');
    final second = _entry('second');
    final both = [first, second];
    await tester.pumpWidget(_app(both, _naming(first)));
    await tester.pump();
    await tester.pumpWidget(_app(both, _naming(second)));
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    await tester.pumpWidget(_app(both, const SizedBox.shrink()));
    await tester.pump();

    // Twice: one run can pass on a queue that the next finds stuck.
    for (final id in ['late', 'later']) {
      first.container.listen<String>(_row(id), (_, _) {}).close();
      await tester.pump();
      await tester.pump();
    }

    expect(_disposed, containsAll(['late', 'later']));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a server renamed while its own scope rebuilds is shown under '
      'the new name', (tester) async {
    final first = _entry('first');
    await tester.pumpWidget(_app([first], _naming(first)));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);

    first.container.read(_renamed.notifier).state = 'renamed';
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('renamed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a row still on screen when its account is removed keeps the '
      'name it had', (tester) async {
    final first = _entry('first');
    await tester.pumpWidget(_app([], _naming(first)));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);

    first.container.dispose();
    await tester.pumpWidget(_app([], _naming(first)));

    expect(tester.takeException(), isNull);
    expect(find.text('first'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets("an icon is fetched with its own server's container", (
    tester,
  ) async {
    final first = _entry('first');
    final second = _entry('second', iconUpdatedAt: 7);
    await tester.pumpWidget(
      _app(
        [first, second],
        UncontrolledProviderScope(
          container: first.container,
          child: Theme(
            data: buildTheme(Brightness.light, AppTokens.light),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ServerIdentity(
                entry: second,
                builder: (context, name, at) => ServerIconTile(
                  entry: second,
                  name: name,
                  iconUpdatedAt: at,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(_iconFetches, ['second']);
    expect(
      tester.widget<SpaceIconImage>(find.bySubtype<SpaceIconImage>()).bytes,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
