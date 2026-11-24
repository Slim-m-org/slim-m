// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two routes that show a nav beside a pane, with the open pane and any
/// page inside it carried in the location so a reload or a pasted link lands
/// on it.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../features/settings/screens/personal_settings_screen.dart';
import '../features/settings/screens/space_settings_screen.dart';
import '../link_query.dart';
import 'modal_page.dart';
import 'routes.dart';

/// Space pane ids that were renamed, so a saved link to the old one still opens.
const _spacePaneAliases = {'performance': 'retention'};

/// The Space pane a `?pane=` value names, after [_spacePaneAliases].
@visibleForTesting
String? resolveSpacePaneId(String? id) => _spacePaneAliases[id] ?? id;

/// `replace` rather than `go`: it keeps the page, so picking a pane neither
/// replays the transition nor drops the shell the modal sits over.
Page<void> personalSettingsPage(
  BuildContext context,
  GoRouterState state,
) => modalPage(
  context,
  PersonalSettingsScreen(
    initialPaneId: queryParam(state.uri, settingsPaneQuery),
    initialPageId: queryParam(state.uri, settingsPageQuery),
    focusAbout: queryParam(state.uri, settingsFocusQuery) == settingsFocusAbout,
    onPaneChanged: (id) => context.replace(
      id == null ? Routes.personalSettings : Routes.personalSettingsPane(id),
    ),
    onPageChanged: (pane, page) => context.replace(
      page == null
          ? Routes.personalSettingsPane(pane)
          : Routes.personalSettingsPage(pane, page),
    ),
  ),
);

Page<void> spaceSettingsPage(BuildContext context, GoRouterState state) =>
    modalPage(
      context,
      SpaceSettingsScreen(
        initialPaneId: resolveSpacePaneId(
          queryParam(state.uri, settingsPaneQuery),
        ),
        onPaneChanged: (id) => context.replace(
          id == null ? Routes.spaceSettings : Routes.spaceSettingsPane(id),
        ),
      ),
      maxWidth: kSpaceSettingsModalMaxWidth,
      maxHeight: kSpaceSettingsModalMaxHeight,
    );
