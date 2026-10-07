// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the rail's fixed bars: the header's menu, and the user footer
/// where the avatar is the status switcher and the bar keeps its content clear
/// of the home indicator.
///
/// Both halves of the footer shipped broken. The avatar was a bare widget with
/// no gesture wrapper anywhere in the file, so the only way to appear offline
/// was two taps and a scroll into settings; and the footer painted its lower
/// 34 points under the home indicator on every notched phone.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/presence_menu.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// The insets of an iPhone with a notch, in logical points, matching
/// `rail_safe_area_test.dart`: 59 for the status bar, 34 for the home
/// indicator.
const double _topInset = 59;
const double _bottomInset = 34;
const double _dpr = 3;
const double _viewHeight = 932;

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Stands in for the real [SyncController], which opens a websocket from its
/// own constructor as soon as the session is signed in. Dart dispatches
/// virtually even from a base constructor, so overriding `start` is enough to
/// keep it off the network; [status] then fixes the value the footer reads.
class _StubSyncController extends SyncController {
  _StubSyncController(super.ref, SyncStatus status) {
    state = status;
  }

  @override
  Future<void> start() async {}
}

/// A container wired like the app's, with the network swapped for a client
/// that answers the two endpoints the footer reaches (`/me` for the name and
/// avatar, `/presence` for a status change) and 404s everything else.
({ProviderContainer container, List<http.Request> requests}) _setup(
  SyncStatus status, {
  int permissions = 0,
  List<Override> extraOverrides = const [],
}) {
  final requests = <http.Request>[];
  final container = ProviderContainer(
    overrides: [
      ...extraOverrides,
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(
        (ref) => _StubSyncController(ref, status),
      ),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'permissions': permissions,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/presence') {
              return http.Response(
                jsonEncode({'visibility': 'hidden'}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              '{}',
              404,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  return (container: container, requests: requests);
}

/// Pumps the footer alone on a view that reports notch and home-indicator
/// insets, at [textScale] so the row can be checked for overflow.
Future<void> _pumpFooter(
  WidgetTester tester,
  ProviderContainer container, {
  double width = 430,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width * _dpr, _viewHeight * _dpr);
  tester.view.devicePixelRatio = _dpr;
  tester.view.padding = FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  tester.view.viewPadding = FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: child!,
        ),
        home: const Scaffold(
          body: Column(children: [Spacer(), RailUserFooter()]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the header alone, which needs no insets: what it is asked about here
/// is the menu its chevron opens, not where the bar sits.
Future<void> _pumpHeader(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: Column(children: [RailHeader()])),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The footer's own painted background, which its [Container] builds as the
/// outermost [DecoratedBox] under [RailUserFooter].
///
/// Asserting on [RailUserFooter] itself cannot see this: a [SafeArea] wrapping
/// the whole bar contributes its own [Padding] render box, which still reaches
/// the edge, so the vacuous form of this test passed against the very mistake
/// it names. The raised fill is the thing that has to reach the edge.
Finder _footerBackground() => find
    .descendant(
      of: find.byType(RailUserFooter),
      matching: find.byType(DecoratedBox),
    )
    .first;

void main() {
  testWidgets('tapping the footer avatar opens a status sheet offering '
      'every visibility, appear-offline included', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    // This file's default width (430) is phone-sized, so this is the sheet; presence_visibility_test.dart covers the wide-window AppMenu case.
    await _pumpFooter(tester, setup.container);

    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();

    expect(
      find.byType(BottomSheet),
      findsOneWidget,
      reason: 'an anchored surface under a thumb is the bug this avoids',
    );
    for (final (_, label, _) in presenceOptions) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '$label must be offered',
      );
    }
    expect(
      find.text('Appear offline'),
      findsOneWidget,
      reason:
          'appear-offline is the whole point of putting this on the '
          'avatar; it must never be the one that is missing',
    );
  });

  testWidgets('picking appear offline sends it and stops the footer '
      'claiming online', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    // Chosen explicitly, the way the sibling test below does: the provider
    // starts at null (no choice known this session) rather than at online.
    setup.container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.online;
    await _pumpFooter(tester, setup.container);

    expect(find.text('online'), findsOneWidget);

    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appear offline'));
    await tester.pumpAndSettle();

    final patches = setup.requests.where(
      (r) => r.url.path == '/presence' && r.method == 'PATCH',
    );
    expect(patches, hasLength(1));
    expect(jsonDecode(patches.first.body), {'visibility': 'hidden'});
    expect(
      setup.container.read(presenceVisibilityDisplayProvider),
      api.PresenceVisibility.hidden,
    );
    expect(find.text('appearing offline'), findsOneWidget);
    expect(find.text('online'), findsNothing);
  });

  // The Space's connection is SpaceConnectionDot's job in the header now.
  testWidgets('the footer keeps reporting the chosen status regardless of '
      'the socket\'s own connection', (tester) async {
    final setup = _setup(SyncStatus.offline);
    addTearDown(setup.container.dispose);
    setup.container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.online;
    await _pumpFooter(tester, setup.container);

    expect(
      find.text('online'),
      findsOneWidget,
      reason:
          'the header\'s SpaceConnectionDot is what reports the socket now, '
          'so this row must not blank out a person\'s own chosen status',
    );
    expect(find.text('offline'), findsNothing);
  });

  testWidgets('the footer keeps its content clear of the home indicator '
      'while its background reaches the edge', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    await _pumpFooter(tester, setup.container);

    expect(
      tester.getRect(find.byType(UserAvatar)).bottom,
      lessThanOrEqualTo(_viewHeight - _bottomInset),
      reason: 'the avatar sat under the home indicator before this',
    );
    expect(
      tester.getRect(_footerBackground()).bottom,
      _viewHeight,
      reason:
          'insetting the bar itself would leave a scaffold-coloured '
          'band below the rail',
    );
    expect(
      tester.getRect(_footerBackground()).bottom,
      greaterThan(tester.getRect(find.byType(UserAvatar)).bottom),
      reason:
          'the background has to extend below the content it insets, or '
          'nothing is painted behind the home indicator',
    );
  });

  testWidgets('the footer does not overflow with a 44pt avatar target at '
      'phone width and larger text', (tester) async {
    for (final scale in [1.0, 1.3]) {
      final setup = _setup(SyncStatus.live);
      await _pumpFooter(tester, setup.container, width: 390, textScale: scale);
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
      setup.container.dispose();
    }
  });

  // The owner's own request: "reduce x and y padding a bit" on the footer.
  testWidgets('the footer padding is trimmed to the spacing scale, not '
      'reinflated back toward its old values', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    await _pumpFooter(tester, setup.container);

    final padding = tester
        .widget<Padding>(find.byKey(const Key('rail-footer-padding')))
        .padding;
    expect(
      padding,
      const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
    );
  });

  // Padding may shrink, but the mic, deafen and settings hit targets must not.
  testWidgets('the footer\'s mic, deafen and settings controls keep their '
      'pointer-density hit target after the padding trim', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    await _pumpFooter(tester, setup.container, width: 1400);

    final buttons = find.descendant(
      of: find.byType(RailUserFooter),
      matching: find.byType(AppIconButton),
    );
    expect(buttons, findsNWidgets(3), reason: 'mic, deafen, settings');
    for (final element in buttons.evaluate()) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.shortestSide, greaterThanOrEqualTo(AppSizes.rowPointer));
    }
  });

  // One deployment is a Space. The header's chevron opens what that Space is
  // and how it is run, so "Server menu" named the machine behind it instead.
  testWidgets('the header menu is announced as the Space menu, and opens '
      'Space settings, for a caller who can manage the Space', (tester) async {
    final setup = _setup(SyncStatus.live, permissions: Perm.manageServer);
    addTearDown(setup.container.dispose);
    await _pumpHeader(tester, setup.container);

    expect(find.bySemanticsLabel('Server menu'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Space settings'), findsOneWidget);
  });

  // Every member keeps the menu for Saved messages and Mark all as read; only Space settings is gated.
  testWidgets('the header menu for a member holding none of the Space settings '
      'gating bits offers no Space settings', (tester) async {
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    await _pumpHeader(tester, setup.container);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Saved messages'), findsOneWidget);
    expect(find.text('Space settings'), findsNothing);
  });

  // A version is not a property of the Space; it duplicated the desktop title bar's own copy.
  testWidgets('the subtitle never repeats this build\'s version', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
    );
    final setup = _setup(SyncStatus.live);
    addTearDown(setup.container.dispose);
    await _pumpHeader(tester, setup.container);

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data?.contains('9.9.9') ?? false),
      ),
      findsNothing,
      reason:
          'a version shown here as well as in the title bar reads as a '
          'typo, not agreement',
    );
  });

  // The rail is a fixed width; a long name must still fit it.
  testWidgets('the header does not overflow at the rail\'s narrowest width '
      'with a long Space name', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.25.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final setup = _setup(
      SyncStatus.live,
      extraOverrides: [
        serverInfoProvider.overrideWith(
          (ref) => Future.value(
            const api.Version(
              name: 'A Very Long Self-Hosted Community Space Name Indeed',
              version: '0.30.0',
              protocol: 1,
            ),
          ),
        ),
      ],
    );
    addTearDown(setup.container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: setup.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: ChannelRail.mediumWidth,
                child: RailHeader(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(RailHeader)).width,
      ChannelRail.mediumWidth,
      reason:
          'the header must stay inside the rail\'s fixed width rather than '
          'a long name pushing it wider',
    );
  });

  // SpaceConnectionDot's own tests are channel_rail_connection_dot_test.dart.
}
