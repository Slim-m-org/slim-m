// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves `expectSettled` actually discriminates a mid-flight capture from
/// a genuinely settled one, rather than trusting the mechanism by reading
/// it - the same standard `real_shadows_test.dart` holds itself to.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mid_flight_capture.dart';

/// Starts showing `'Loading...'` and, once [resolve] completes, rebuilds
/// showing its value - `ReportCard`'s own nested-resolve shape, driven by a
/// `Completer` so the test controls exactly when the second hop lands
/// rather than racing a real timer.
class _NestedResolveLabel extends StatefulWidget {
  const _NestedResolveLabel(this.resolve);

  final Future<String> resolve;

  @override
  State<_NestedResolveLabel> createState() => _NestedResolveLabelState();
}

class _NestedResolveLabelState extends State<_NestedResolveLabel> {
  String _label = 'Loading...';

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.resolve.then((value) {
        if (mounted) setState(() => _label = value);
      }),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: TextDirection.ltr, child: Text(_label));
}

/// Content behind an entrance fade whose ticker starts on mount - the
/// `AppAsyncView`-over-`AppFadeIn` shape that once captured whole admin
/// panes at opacity zero. Bare pumps never move it; timed ones land it.
class _LateFadeLabel extends StatefulWidget {
  const _LateFadeLabel();

  @override
  State<_LateFadeLabel> createState() => _LateFadeLabelState();
}

class _LateFadeLabelState extends State<_LateFadeLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _controller, child: const Text('faded in'));
}

void main() {
  testWidgets('renderedText reads both plain and rich Text content', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Text('plain'),
            Text.rich(TextSpan(text: 'rich')),
          ],
        ),
      ),
    );

    expect(renderedText(tester), ['plain', 'rich']);
  });

  testWidgets(
    'fails when a resolve already completed lands only on a further pump',
    (tester) async {
      final completer = Completer<String>();
      await tester.pumpWidget(_NestedResolveLabel(completer.future));
      completer.complete('Resolved');

      await expectLater(
        () => expectSettled(tester, 'nested-resolve-probe'),
        throwsA(isA<TestFailure>()),
      );
    },
  );

  testWidgets('knownTransient swallows exactly that same difference', (
    tester,
  ) async {
    final completer = Completer<String>();
    await tester.pumpWidget(_NestedResolveLabel(completer.future));
    completer.complete('Resolved');

    await expectSettled(tester, 'nested-resolve-probe', knownTransient: true);
  });

  testWidgets('passes once the resolve already landed before the read', (
    tester,
  ) async {
    final completer = Completer<String>();
    await tester.pumpWidget(_NestedResolveLabel(completer.future));
    completer.complete('Resolved');
    await tester.pump();
    await tester.pump();
    expect(renderedText(tester), ['Resolved']);

    await expectSettled(tester, 'nested-resolve-probe');
  });

  testWidgets('passes on a surface with nothing left to resolve at all - the '
      'perpetual-spinner case this must never hang on', (tester) async {
    final completer = Completer<String>();
    await tester.pumpWidget(_NestedResolveLabel(completer.future));

    await expectSettled(tester, 'never-resolves-probe');
    expect(renderedText(tester), ['Loading...']);
  });

  testWidgets('text an ancestor holds at zero opacity is not "rendered"', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Opacity(opacity: 0, child: Text('invisible')),
            Opacity(opacity: 0.5, child: Text('dim')),
            Text('visible'),
          ],
        ),
      ),
    );

    expect(renderedText(tester), ['dim', 'visible']);
  });

  testWidgets(
    'fails content that only fades in while the extra pumps advance time - '
    'the invisible-admin-pane shape',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: _LateFadeLabel(),
        ),
      );
      await tester.pump();
      expect(renderedText(tester), isEmpty, reason: 'fade still at t=0');

      await expectLater(
        () => expectSettled(tester, 'late-fade-probe'),
        throwsA(isA<TestFailure>()),
      );
    },
  );

  testWidgets('a live clock ticking across the timed pumps is settled, '
      'a resolving placeholder is not', (tester) async {
    var seconds = 41;
    late StateSetter rebuild;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Text('673:52:$seconds');
          },
        ),
      ),
    );
    // Drive the tick the way a real timer would: bump on each extra pump.
    final ticker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      rebuild(() => seconds++);
    });

    await expectSettled(tester, 'clock-probe');
    ticker.cancel();
  });

  testWidgets('fails a settled surface with no visible text at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(textDirection: TextDirection.ltr, child: SizedBox()),
    );

    await expectLater(
      () => expectSettled(tester, 'blank-probe'),
      throwsA(isA<TestFailure>()),
    );
  });

  testWidgets('allowNoText lets a genuinely text-free surface pass', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(textDirection: TextDirection.ltr, child: SizedBox()),
    );

    await expectSettled(tester, 'blank-probe', allowNoText: true);
  });
}
