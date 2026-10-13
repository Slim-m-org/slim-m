// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The thread parent the capture fixtures answer with: a real message in
/// #general carrying a file, so the thread panel's parent block renders.
library;

const fixtureThreadParent = {
  'parent_channel_id': 'c-general',
  'parent_channel_name': 'general',
  'parent_message_id': 'msg-thread-parent',
  'parent_content': 'The canvas undo drops the last stroke after a reconnect.',
  'parent_deleted': false,
  'parent_author_id': 'user-nick',
  'parent_author_display_name': 'Nick',
  'parent_attachments': [
    {
      'id': 'att-repro',
      'filename': 'repro-steps.pdf',
      'content_type': 'application/pdf',
      'size': 48213,
    },
  ],
};
