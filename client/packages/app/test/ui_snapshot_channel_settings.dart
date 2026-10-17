// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A snapshot route to the real Channel settings screen for #general, which
/// the surfaces matrix had no way to reach: the routed screen needs the
/// channel as `extra`, and the matrix navigates by path alone.
library;

import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_data/data.dart' show Channel;

final _general = const Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

final channelSettingsFixtureRoute = GoRoute(
  path: Routes.channelSettings,
  pageBuilder: (context, state) => modalPage(
    context,
    ChannelSettingsScreen(
      args: ChannelSettingsRouteArgs(channel: _general, wasOpen: false),
    ),
  ),
);
