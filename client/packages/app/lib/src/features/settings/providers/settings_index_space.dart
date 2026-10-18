// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings half of the settings search index; see `settings_index.dart`.
library;

import 'settings_index.dart';

const spaceSettingsIndex = <SettingsEntry>[
  SettingsEntry('reports', 'Reported user', keywords: ['moderation']),
  SettingsEntry('reports', 'Reported message', keywords: ['moderation']),
  SettingsEntry(
    'removed-members',
    'Removed members',
    description: 'Letting someone back in restores their access.',
    keywords: ['ban', 'kick', 'unban'],
  ),
  SettingsEntry('invites', 'Invites', keywords: ['invite link', 'join']),
  SettingsEntry('invites', 'New invite', keywords: ['invite link']),
  SettingsEntry('invites', 'Expires'),
  SettingsEntry('invites', 'Joining', keywords: ['join policy']),
  SettingsEntry('invites', 'Join gate', keywords: ['approval', 'verification']),
  SettingsEntry(
    'invites',
    'Landing page',
    description: 'What an invite link shows before sign-in.',
  ),
  SettingsEntry('invites', 'Banner', keywords: ['space banner']),
  SettingsEntry('invites', 'Icon', keywords: ['space icon']),
  SettingsEntry('invites', 'Preview'),
  SettingsEntry(
    'account-recovery',
    'Reset codes',
    description:
        "Locked-out members get back in with an administrator's one-time code.",
    keywords: ['password reset', 'recovery', 'locked out'],
  ),
  SettingsEntry(
    'account-recovery',
    'Password reset code',
    description: 'Pick a member, confirm your password, hand them the code.',
  ),
  SettingsEntry('roles', 'Messages', keywords: ['permissions']),
  SettingsEntry('roles', 'Moderation', keywords: ['permissions']),
  SettingsEntry(
    'roles',
    'Administrator',
    description:
        'Every permission below, in every channel, ignoring overrides.',
    keywords: ['admin', 'permissions'],
  ),
  SettingsEntry(
    'roles',
    'Send messages',
    description: 'Post in text channels this role can see.',
  ),
  SettingsEntry(
    'roles',
    'Manage messages',
    description: "Delete and pin other people's messages.",
  ),
  SettingsEntry(
    'roles',
    'Attach files',
    description: 'Upload images and files.',
    keywords: ['uploads'],
  ),
  SettingsEntry(
    'roles',
    'Add reactions',
    description: 'React to messages with emoji.',
  ),
  SettingsEntry(
    'roles',
    'Manage roles',
    description: 'Edit and assign roles below this one.',
    keywords: ['role colour', 'role color'],
  ),
  SettingsEntry(
    'roles',
    'Remove members',
    description: 'Remove someone; they can rejoin with an invite.',
    keywords: ['kick'],
  ),
  SettingsEntry(
    'roles',
    'Ban members',
    description: 'Remove someone and block them from rejoining.',
    keywords: ['ban'],
  ),
  SettingsEntry(
    'roles',
    'View moderation history',
    description:
        'Read past moderation actions, without the power to take new ones.',
    keywords: ['audit log', 'modlog'],
  ),
  SettingsEntry('emoji', 'New emoji', keywords: ['custom emoji', 'upload']),
  SettingsEntry('emoji', 'Emoji (0)', conditional: true),
  SettingsEntry(
    'space-voice',
    'Strong by default',
    description: 'Also removes keyboards, fans and room noise.',
    keywords: ['noise suppression', 'noise', 'keyboard'],
  ),
  SettingsEntry(
    'space-voice',
    'Screen share quality',
    description: 'The tallest resolution a share may use.',
    keywords: ['stream', 'resolution'],
  ),
  SettingsEntry(
    'space-voice',
    'Noise suppression',
    description: 'For members who leave it on Space default.',
    keywords: ['noise', 'keyboard'],
  ),
  SettingsEntry(
    'performance',
    'Message retention',
    description: 'How long messages are kept before they are deleted.',
    keywords: ['delete old messages', 'history'],
  ),
  SettingsEntry(
    'performance',
    'Canvas object cap',
    description: 'The most objects one channel canvas can hold.',
  ),
  SettingsEntry(
    'performance',
    'Attachment size limit',
    description: 'Largest file a member can upload.',
    keywords: ['upload', 'file size', 'max size'],
  ),
  SettingsEntry(
    'analytics',
    'Record Space analytics',
    description:
        'Counts messages and server memory use, never per-member activity.',
    keywords: ['stats', 'statistics'],
  ),
  SettingsEntry('analytics', 'Overview', keywords: ['stats']),
  SettingsEntry('analytics', 'Messages, last 30 days'),
  SettingsEntry('analytics', 'Active hours, last 30 days (UTC)'),
  SettingsEntry('analytics', 'Server memory use', keywords: ['ram']),
  SettingsEntry('analytics', 'Attachment storage by member'),
  SettingsEntry(
    'audit-log',
    'Audit log',
    description: 'Every change admins made to this Space.',
    keywords: ['history', 'changes', 'admin', 'log'],
    conditional: true,
  ),
  SettingsEntry('server-metrics', 'System', keywords: ['cpu', 'memory']),
  SettingsEntry('server-metrics', 'Request volume by class'),
  SettingsEntry('server-metrics', 'Slowest routes', keywords: ['latency']),
  SettingsEntry(
    'dock',
    'Code Blocks',
    description: 'Run code snippets in a channel and post the output.',
    keywords: ['modules', 'dock', 'addons'],
    conditional: true,
  ),
  SettingsEntry('bots', 'Create bot', keywords: ['bot token']),
  SettingsEntry('bots', 'Bots in this Space'),
  SettingsEntry('webhooks', 'Create webhook'),
  SettingsEntry('webhooks', 'Webhooks in this Space'),
];
