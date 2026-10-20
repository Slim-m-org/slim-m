// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one spelling of each action and pane name that more than one surface
/// shows. The rules behind them are in `docs/design/wording.md`.
library;

abstract final class ActionLabels {
  static const createChannel = 'Create channel';
  static const createCategory = 'Create category';
  static const createRole = 'Create role';
  static const createInvite = 'Create invite';
  static const createEmoji = 'Create emoji';
  static const createBot = 'Create bot';
  static const createWebhook = 'Create webhook';
  static const createResetCode = 'Create a reset code';

  /// Reactions are attached, not created; every surface says exactly this.
  static const addReaction = 'Add reaction';

  static const removeMembers = 'Remove members';
  static const removeFromSpace = 'Remove from Space...';

  /// This device's media and cache options, not the Space's limits.
  static const mediaAndCache = 'Media and cache';

  /// The Space's message retention and canvas cap, not this device's options.
  static const retentionAndLimits = 'Retention and limits';

  /// The Space's call defaults: screen-share quality and noise suppression.
  static const spaceVoice = 'Voice and screen share';

  /// The Space settings group for how the Space is running.
  static const operationsGroup = 'Operations';
}
