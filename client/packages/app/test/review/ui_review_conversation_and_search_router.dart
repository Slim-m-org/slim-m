// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A router for the routes the shared fixture's does not carry: the channel's
/// `?chat=1` hand-off, a message link, and settings routes with their own arguments.
library;

import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/messages/screens/message_deep_link.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';

/// The app's shell on `/channels`, with [routes] ahead of it for anything pushed over it.
GoRouter reviewRouter(String initial, {List<RouteBase> routes = const []}) =>
    GoRouter(
      initialLocation: initial,
      routes: [
        ...routes,
        GoRoute(
          path: '/thread/:channelId',
          pageBuilder: (context, state) => modalPage(
            context,
            ThreadScreen(channelId: state.pathParameters['channelId']!),
          ),
        ),
        ShellRoute(
          builder: (context, state, child) => HomeShell(child: child),
          routes: [
            GoRoute(
              path: Routes.channels,
              builder: (context, state) => const NoChannelSelected(),
              routes: [
                GoRoute(
                  path: ':channelId',
                  builder: (context, state) => ConversationPane(
                    channelId: state.pathParameters['channelId']!,
                    openChat: state.uri.queryParameters['chat'] == '1',
                  ),
                ),
                GoRoute(
                  path: Routes.messagePattern,
                  builder: (context, state) => MessageDeepLink(
                    channelId: state.pathParameters['channelId']!,
                    messageId: state.pathParameters['messageId']!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
