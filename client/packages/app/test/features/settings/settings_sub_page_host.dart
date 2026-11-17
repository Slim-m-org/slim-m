// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mounts settings sub-pages inside a real Appearance pane, the way the app
/// shows them, for a test that drives one page.
library;

import 'package:flutter/material.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';

const _hostPage = 'host';

/// Settings opened on Appearance with [pages] pushed, bottom first.
Widget settingsSubPageHost(List<SettingsSubPage> Function() pages) =>
    SettingsPanesScaffold(
      title: 'Settings',
      backTooltip: 'Back to channels',
      backFallback: '/',
      initialPaneId: 'appearance',
      initialPageId: _hostPage,
      groups: [
        SettingsPaneGroup(
          label: 'You',
          panes: [
            SettingsPane(
              id: 'appearance',
              label: 'Appearance',
              builder: (_) => const SizedBox.shrink(),
              subPages: {_hostPage: pages},
            ),
          ],
        ),
      ],
    );
