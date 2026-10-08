// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two routes that show a nav beside a pane, with the open pane carried
/// in the location so a reload or a pasted link lands on it.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../screens/personal_settings_screen.dart';
import '../screens/space_settings_screen.dart';
import 'modal_page.dart';
import 'routes.dart';

/// `replace` rather than `go`: it keeps the page, so picking a pane neither
/// replays the transition nor drops the shell the modal sits over.
Page<void> personalSettingsPage(BuildContext context, GoRouterState state) =>
    modalPage(
      context,
      PersonalSettingsScreen(
        initialPaneId: state.uri.queryParameters[settingsPaneQuery],
        onPaneChanged: (id) => context.replace(
          id == null
              ? Routes.personalSettings
              : Routes.personalSettingsPane(id),
        ),
      ),
    );

Page<void> spaceSettingsPage(BuildContext context, GoRouterState state) =>
    modalPage(
      context,
      SpaceSettingsScreen(
        initialPaneId: state.uri.queryParameters[settingsPaneQuery],
        onPaneChanged: (id) => context.replace(
          id == null ? Routes.spaceSettings : Routes.spaceSettingsPane(id),
        ),
      ),
      maxWidth: kSpaceSettingsModalMaxWidth,
      maxHeight: kSpaceSettingsModalMaxHeight,
    );
