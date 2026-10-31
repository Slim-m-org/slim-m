// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the assembled shell publishes to a screen reader.
///
/// Driving the web build found the channel rail publishing no accessibility
/// nodes at all, and it reproduced here with no browser involved: a modal
/// barrier inside the conversation pane's navigator carries
/// `BlockSemantics(blocking: true)`, which drops everything painted before it.
/// The rail paints before that pane and the member pane paints after, which is
/// why only the rail vanished and why it read as a rail bug.
///
/// These assert the assembled shell rather than a widget on its own, because
/// every one of them passed in isolation while the app shipped a rail no
/// screen reader could see.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

/// Wide enough for the rail, the conversation and the member pane at once.
const Size _desktop = Size(1400, 900);

/// Renders the real shell with semantics on, runs [body], then unwinds.
///
/// The handle is disposed inside the test rather than by `addTearDown`,
/// because the framework's own end-of-test check runs before tear-downs do and
/// fails on a handle that is merely queued for disposal.
Future<void> withShell(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  tester.view.physicalSize = _desktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final handle = tester.ensureSemantics();
  final fixture = await fixtureContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));

  try {
    await body();
  } finally {
    handle.dispose();
    await teardownFixture(tester, fixture.container, fixture.db);
  }
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the rail names every channel it lists', (tester) async {
    await withShell(tester, () async {
      // Named for a channel that appears nowhere but the rail; 'general' also
      // sits in the conversation header and would pass with the rail blocked.
      expect(find.bySemanticsLabel(RegExp('design')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('main')), findsWidgets);
    });
  });

  testWidgets('the rail names its search control', (tester) async {
    await withShell(tester, () async {
      expect(find.bySemanticsLabel(RegExp('Search channels')), findsWidgets);
    });
  });

  testWidgets('a foldable rail section is announced as an expandable button', (
    tester,
  ) async {
    await withShell(tester, () async {
      final node = tester.getSemantics(find.bySemanticsLabel('Text'));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isExpanded, Tristate.isTrue);
    });
  });

  testWidgets('a section that does not fold is announced as a heading', (
    tester,
  ) async {
    await withShell(tester, () async {
      final node = tester.getSemantics(find.bySemanticsLabel('Channels'));
      expect(node.flagsCollection.isHeader, isTrue);
    });
  });

  testWidgets('a member nobody has reported on is announced by name alone', (
    tester,
  ) async {
    await withShell(tester, () async {
      expect(find.bySemanticsLabel(RegExp('Ada Lovelace')), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp('Ada Lovelace, offline')),
        findsNothing,
      );
    });
  });

  testWidgets('nobody is announced as muted for being offline', (tester) async {
    await withShell(tester, () async {
      // The fixture's voice channel joins muted; that label is about the channel, not a member.
      expect(find.bySemanticsLabel(RegExp('(?<!Joins )muted')), findsNothing);
    });
  });

  testWidgets('a message names its author once', (tester) async {
    await withShell(tester, () async {
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Long enough to wrap')),
      );
      expect('Ada Lovelace'.allMatches(node.label).length, 1);
    });
  });

  testWidgets('a member is named once, not once per widget', (tester) async {
    await withShell(tester, () async {
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Ada Lovelace')).first,
      );
      expect('Ada Lovelace'.allMatches(node.label).length, 1);
    });
  });
}
