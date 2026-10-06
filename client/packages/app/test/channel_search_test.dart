// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the channel search panel's loading, error, and empty states: a
/// failed search must say so and offer a retry (unless the failure was a
/// 403, which no retry can fix), and must never render identically to a
/// search that genuinely found nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/channel_search.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('the search field has an accessible name', (tester) async {
    await tester.pumpWidget(
      _harness(
        ChannelSearchBar(
          controller: TextEditingController(),
          onChanged: (_) {},
        ),
      ),
    );

    // Substring, not equality: AppInput also exposes its placeholder as the field's own hint, which merges into the same node.
    expect(
      find.bySemanticsLabel(RegExp('Search this channel')),
      findsOneWidget,
    );
  });

  testWidgets('a genuinely empty result announces "No matches." as a live '
      'region', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ChannelSearchResults(
          results: [],
          knownUsernames: {},
          loading: false,
          failed: false,
          forbidden: false,
          onRetry: _noop,
          onSelect: _noopMessage,
        ),
      ),
    );

    final region = tester.widget<Semantics>(
      find.byKey(ChannelSearchResults.liveRegionKey),
    );
    expect(region.properties.liveRegion, isTrue);
    expect(region.properties.label, 'No matches.');
  });

  testWidgets('a search in flight shows a spinner, not "no matches"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ChannelSearchResults(
          results: null,
          knownUsernames: {},
          loading: true,
          failed: false,
          forbidden: false,
          onRetry: _noop,
          onSelect: _noopMessage,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No matches.'), findsNothing);
  });

  testWidgets('a failed search says so and offers a working retry', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      _harness(
        ChannelSearchResults(
          results: null,
          knownUsernames: const {},
          loading: false,
          failed: true,
          forbidden: false,
          onRetry: () => retried = true,
          onSelect: _noopMessage,
        ),
      ),
    );

    expect(find.text('Search failed.'), findsOneWidget);
    expect(
      find.text('No matches.'),
      findsNothing,
      reason: 'a failure must never read as an honest empty result',
    );

    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('a 403 explains the denial and offers no retry', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ChannelSearchResults(
          results: null,
          knownUsernames: {},
          loading: false,
          failed: true,
          forbidden: true,
          onRetry: _noop,
          onSelect: _noopMessage,
        ),
      ),
    );

    expect(
      find.text('You do not have permission to search this channel.'),
      findsOneWidget,
    );
    expect(
      find.text('Retry'),
      findsNothing,
      reason: 'a 403 will not succeed on retry, so none is offered',
    );
  });

  testWidgets('a failed search is an AppErrorState, a 403 one without retry', (
    tester,
  ) async {
    Widget results({required bool forbidden}) => _harness(
      ChannelSearchResults(
        results: null,
        knownUsernames: const {},
        loading: false,
        failed: true,
        forbidden: forbidden,
        onRetry: _noop,
        onSelect: _noopMessage,
      ),
    );

    await tester.pumpWidget(results(forbidden: false));
    final failed = tester.widget<AppErrorState>(find.byType(AppErrorState));
    expect(failed.onRetry, isNotNull);

    await tester.pumpWidget(results(forbidden: true));
    final denied = tester.widget<AppErrorState>(find.byType(AppErrorState));
    expect(denied.onRetry, isNull);
  });

  testWidgets('a genuinely empty result reads as "no matches"', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ChannelSearchResults(
          results: [],
          knownUsernames: {},
          loading: false,
          failed: false,
          forbidden: false,
          onRetry: _noop,
          onSelect: _noopMessage,
        ),
      ),
    );

    expect(find.text('No matches.'), findsOneWidget);
  });
}

void _noop() {}

void _noopMessage(api.Message _) {}
