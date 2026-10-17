// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Imports point down the layers: a widget never imports a screen, and a
/// provider never imports a widget or a screen, in a feature folder or the
/// shared one. The known exceptions are listed and may only shrink.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each is `importer -> imported`, relative to lib/src. Fix one by moving the
/// shared piece down a layer, then delete its line.
const _knownExceptions = {
  // Widgets that open a screen or pane.
  'features/canvas/widgets/canvas_open_button.dart -> features/canvas/screens/canvas_pane.dart',
  'features/channels/widgets/channel_row_menu.dart -> features/channels/screens/channel_settings_screen.dart',
  'features/channels/widgets/compact_channel_app_bar.dart -> features/voice/screens/voice_text_pane.dart',
  'features/channels/widgets/dm_row.dart -> features/voice/screens/dm_call_pane.dart',
  'features/channels/widgets/rail_call_summary.dart -> features/voice/screens/dm_call_pane.dart',
  'features/voice/widgets/call_mini_player.dart -> features/voice/screens/dm_call_pane.dart',
  'features/voice/widgets/dm_call_button.dart -> features/voice/screens/dm_call_pane.dart',
  'features/voice/widgets/voice_strip_indicator.dart -> features/voice/screens/dm_call_pane.dart',
  'widgets/compact_drawer_scaffold.dart -> features/voice/screens/voice_text_pane.dart',
  // Widgets that list the Space settings panes or reuse a screen's helper.
  'features/channels/widgets/channel_settings_retention_row.dart -> features/settings/screens/admin/performance_screen.dart',
  'features/palette/widgets/command_palette_items.dart -> features/settings/screens/space_settings_section.dart',
  'widgets/space_menu_button.dart -> features/settings/screens/space_settings_section.dart',
  // Providers that reuse a widget's helper.
  'features/auth/providers/database_key_store.dart -> widgets/banner_host_layout.dart',
  'features/auth/providers/server_identity_recheck.dart -> features/auth/widgets/server_identity_confirmation.dart',
  'features/composer/providers/composer_attachment_drop.dart -> features/composer/widgets/composer_attachments.dart',
  'features/members/providers/user_profiles.dart -> features/messages/widgets/author_label.dart',
  'features/messages/providers/link_preview.dart -> features/channels/widgets/channel_rail_frame.dart',
  'features/messages/providers/message_alert_policy.dart -> features/messages/widgets/message_mentions.dart',
  'features/voice/providers/voice_controller.dart -> features/voice/widgets/video_health_overlay.dart',
  'providers/desktop_notification_text.dart -> features/messages/widgets/reply_target_summary.dart',
};

/// Directives start a line, so a commented-out import never matches.
final _directive = RegExp(r"^(?:import|export) '([^']+)'", multiLine: true);

String? _layer(String path) {
  final parts = path.split('/');
  for (final layer in const ['screens', 'widgets', 'providers']) {
    if (parts.contains(layer)) return layer;
  }
  return null;
}

String _normalize(String path) {
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part == '..') {
      out.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      out.add(part);
    }
  }
  return out.join('/');
}

Set<String> _wrongWayImports(String srcRoot) {
  final found = <String>{};
  for (final file in Directory(srcRoot).listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    final from = file.path.substring(srcRoot.length + 1);
    final fromLayer = _layer(from);
    if (fromLayer != 'widgets' && fromLayer != 'providers') continue;
    final dir = from.contains('/')
        ? from.substring(0, from.lastIndexOf('/'))
        : '';
    for (final match in _directive.allMatches(file.readAsStringSync())) {
      final uri = match.group(1)!;
      final String to;
      if (uri.startsWith('package:slimm_app/src/')) {
        to = uri.substring('package:slimm_app/src/'.length);
      } else if (uri.startsWith('package:') || uri.startsWith('dart:')) {
        continue;
      } else {
        to = _normalize('$dir/$uri');
      }
      final toLayer = _layer(to);
      final wrong = fromLayer == 'widgets'
          ? toLayer == 'screens'
          : toLayer == 'widgets' || toLayer == 'screens';
      if (wrong) found.add('$from -> $to');
    }
  }
  return found;
}

void main() {
  test('no new import points up the layers, and fixed ones leave the list', () {
    final found = _wrongWayImports('lib/src');
    expect(
      found.difference(_knownExceptions),
      isEmpty,
      reason: 'a widget imports a screen, or a provider imports a widget',
    );
    expect(
      _knownExceptions.difference(found),
      isEmpty,
      reason: 'fixed: delete these lines from _knownExceptions',
    );
  });
}
