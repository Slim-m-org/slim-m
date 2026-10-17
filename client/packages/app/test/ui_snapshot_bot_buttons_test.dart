// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's buttons in the real shell: every style, a disabled button, a press
/// waiting on the bot, and a press the bot never answered. Its own file
/// because `ui_snapshot_test.dart` is past this repo's line budget; see that
/// file's surface tables for the shape this repeats.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/button_presses.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import 'ui_snapshot_support.dart';

const _styles = [
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'Hit',
        style: api.ComponentButtonStyle.primary,
        customId: 'hit',
      ),
      api.MessageButton(
        label: 'Stand',
        style: api.ComponentButtonStyle.secondary,
        customId: 'stand',
      ),
      api.MessageButton(
        label: 'Fold',
        style: api.ComponentButtonStyle.danger,
        customId: 'fold',
      ),
      api.MessageButton(
        label: 'Double down',
        style: api.ComponentButtonStyle.secondary,
        customId: 'double',
        disabled: true,
      ),
      api.MessageButton(
        label: 'Rules',
        style: api.ComponentButtonStyle.link,
        url: 'https://example.com/rules',
      ),
    ],
  ),
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'A button with a label long enough to test how a row copes',
        style: api.ComponentButtonStyle.secondary,
        customId: 'long',
      ),
    ],
  ),
];

const _confirm = [
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'Confirm',
        style: api.ComponentButtonStyle.primary,
        customId: 'yes',
      ),
      api.MessageButton(
        label: 'Cancel',
        style: api.ComponentButtonStyle.secondary,
        customId: 'no',
      ),
    ],
  ),
];

class _SeededExtras extends MessageExtrasController {
  _SeededExtras(super.ref) {
    state = {
      'm-3': const MessageExtras(components: _styles),
      'm-1': const MessageExtras(components: _confirm),
    };
  }

  // The fixture's own page load would otherwise replace the seeded buttons.
  @override
  void applyMessages(Iterable<api.Message> messages) {}

  @override
  void applyMessage(api.Message message) {}
}

class _SeededPresses extends ButtonPressesController {
  _SeededPresses(super.ref) {
    state = {
      'm-3|hit': const ButtonPress(
        id: 'i-1',
        channelId: 'c-general',
        messageId: 'm-3',
        customId: 'hit',
        status: ButtonPressStatus.pending,
      ),
      'm-1|yes': const ButtonPress(
        id: 'i-2',
        channelId: 'c-general',
        messageId: 'm-1',
        customId: 'yes',
        status: ButtonPressStatus.failed,
        failure:
            'The bot did not answer. It may be offline, so try again in a '
            'moment.',
      ),
    };
  }
}

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final viewportName in phoneAndDesktop) {
      testWidgets('channel-bot-buttons at $viewportName ($theme) fits', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/channels/c-general',
          viewportName,
          theme,
          'channel-bot-buttons-$viewportName-$theme',
          overrides: [
            messageExtrasProvider.overrideWith(_SeededExtras.new),
            buttonPressesProvider.overrideWith(_SeededPresses.new),
          ],
        );
      });
    }
  }
}
