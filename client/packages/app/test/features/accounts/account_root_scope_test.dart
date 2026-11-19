// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An account that leaves the screen keeps a working provider graph: what
/// nothing watches is still disposed and what is derived still refreshes,
/// there and after coming back.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_root.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_server_label.dart';

import 'account_host_harness.dart';

const _first = 'https://first.example';
const _second = 'https://second.example';

final _disposed = <String>[];

final _row = Provider.autoDispose.family<String, String>((ref, id) {
  ref.onDispose(() => _disposed.add(id));
  return id;
});

final _count = StateProvider<int>((ref) => 0);
final _doubled = Provider<int>((ref) => ref.watch(_count) * 2);

/// Which row the app under test watches, so a test can stop watching one.
final _watched = ValueNotifier('one');

/// Whether the app under test shows the other account's name, as an open switcher does.
final _namesOther = ValueNotifier(false);

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => Column(
    textDirection: TextDirection.ltr,
    children: [
      ValueListenableBuilder(
        valueListenable: _watched,
        builder: (context, id, _) => Consumer(
          builder: (context, ref, _) => Text(
            '${ref.watch(_row(id))} ${ref.watch(_doubled)}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ),
      ValueListenableBuilder(
        valueListenable: _namesOther,
        builder: (context, shown, _) => shown ? const _OtherName() : _none,
      ),
    ],
  );
}

const _none = SizedBox.shrink();

/// The first account out of view, named through its own container.
class _OtherName extends ConsumerWidget {
  const _OtherName();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final other = ref
        .watch(accountsSnapshotProvider)
        .entries
        .where((e) => !e.active)
        .firstOrNull;
    if (other == null) return _none;
    return ServerIdentityScope(
      entry: other,
      builder: (context, name, _) =>
          Text(name, textDirection: TextDirection.ltr),
    );
  }
}

void main() {
  late AccountHarness h;

  setUp(() {
    _disposed.clear();
    _watched.value = 'one';
    _namesOther.value = false;
  });

  Future<void> boot(WidgetTester tester) async {
    h = AccountHarness();
    await tester.runAsync(() async {
      await h.seed(_first, user: 'ann', active: true);
      await h.seed(_second, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(AccountRoot(host: h.host, app: const _App()));
    await tester.pump();
  }

  Future<void> switchTo(WidgetTester tester, String origin) async {
    await h.host.switchTo(origin);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an account switched away from disposes what its screen '
      'stopped watching', (tester) async {
    await boot(tester);

    await switchTo(tester, _second);

    expect(_disposed, contains('one'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an account that came back disposes and refreshes as before '
      'it left', (tester) async {
    await boot(tester);
    final first = h.host.runtimeFor(_first)!.container;
    await switchTo(tester, _second);
    await switchTo(tester, _first);
    _disposed.clear();

    _watched.value = 'two';
    await tester.pump();
    await tester.pump();
    expect(_disposed, contains('one'));

    first.read(_count.notifier).state = 21;
    await tester.pump();
    await tester.pump();
    expect(find.text('two 42'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an account out of view survives its name being shown and '
      'hidden again', (tester) async {
    await boot(tester);
    final second = h.host.runtimeFor(_second)!.container;
    _namesOther.value = true;
    await tester.pump();
    await tester.pump();
    expect(find.text('Second'), findsOneWidget);
    _namesOther.value = false;
    await tester.pump();
    await tester.pump();

    second.listen<String>(_row('late'), (_, _) {}).close();
    final seen = <int>[];
    final sub = second.listen<int>(_doubled, (_, next) => seen.add(next));
    addTearDown(sub.close);
    second.read(_count.notifier).state = 4;
    await tester.pump();
    await tester.pump();

    expect(_disposed, contains('late'));
    expect(seen, [8]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an account out of view still refreshes what derives from a '
      'change', (tester) async {
    await boot(tester);
    final first = h.host.runtimeFor(_first)!.container;
    await switchTo(tester, _second);
    final seen = <int>[];
    final sub = first.listen<int>(_doubled, (_, next) => seen.add(next));
    addTearDown(sub.close);

    first.read(_count.notifier).state = 4;
    await tester.pump();
    await tester.pump();

    expect(seen, [8]);
    await tester.pumpWidget(const SizedBox());
  });
}
