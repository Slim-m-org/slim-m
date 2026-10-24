// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What settings search can find: every settings row by pane, label and the
/// words someone might type for it. Panes build their rows lazily, so the
/// labels cannot be read at runtime; `settings_search_index_test.dart` fails
/// when a rendered row is missing here, so the two cannot drift apart.
library;

import 'package:slimm_platform/platform.dart';

import '../../../routing/routes.dart' show desktopPane;
import 'settings_index_gates.dart';

export 'settings_index_gates.dart' show SettingsGate;
export 'settings_index_space.dart';

const _devicesPage = 'account-devices';

/// One searchable setting.
class SettingsEntry {
  const SettingsEntry(
    this.pane,
    this.label, {
    this.description,
    this.keywords = const [],
    this.conditional = false,
    this.available,
    this.gate,
    this.gatedKeywords = const [],
    this.keywordGate,
  });

  /// App state the entry needs to exist, resolved by `settingsGatedEntries`.
  final SettingsGate? gate;

  /// Keywords that only count while [keywordGate] is open.
  final List<String> gatedKeywords;
  final SettingsGate? keywordGate;

  /// Where the row exists at all; null means everywhere.
  final bool Function()? available;

  /// The pane id it lives on, as `?pane=` names it.
  final String pane;

  /// The row's own label, which is also how the pane finds it to highlight.
  final String label;
  final String? description;

  /// Other words for it: what someone types who does not know the label.
  final List<String> keywords;

  /// This entry with [more] added to its keywords.
  SettingsEntry withKeywords(List<String> more) => SettingsEntry(
    pane,
    label,
    description: description,
    keywords: [...keywords, ...more],
    conditional: conditional,
    available: available,
  );

  /// Shown only on some platforms or in some states, so a render may lack it.
  final bool conditional;
}

const personalSettingsIndex = <SettingsEntry>[
  SettingsEntry(
    'profile',
    'How others see you',
    description: 'Updates as you edit below.',
    keywords: ['preview', 'profile card'],
  ),
  SettingsEntry(
    'profile',
    'Identity',
    keywords: ['avatar', 'picture', 'photo', 'display name', 'username'],
  ),
  SettingsEntry(
    'profile',
    'About you',
    keywords: ['bio', 'pronouns', 'profile colour', 'color'],
  ),
  SettingsEntry(
    'profile',
    'Activity',
    description:
        'Shown to people who see your status, never when appearing offline.',
    keywords: ['status', 'rich presence'],
  ),
  SettingsEntry(
    'profile',
    "Show what I'm listening to",
    description: 'Shows the track from a media player on this device.',
    keywords: ['music', 'now playing', 'song', 'media player'],
  ),
  SettingsEntry(
    'profile',
    'Show my current game',
    description: 'Your running Steam game, or one on the list below.',
    keywords: ['game', 'steam', 'playing'],
  ),
  SettingsEntry(
    _devicesPage,
    'Connections',
    description: 'Accounts shown on your profile.',
    keywords: ['discord', 'link', 'linked accounts'],
    gatedKeywords: ['spotify'],
    keywordGate: SettingsGate.spotifyConfigured,
    conditional: true,
  ),
  SettingsEntry(
    _devicesPage,
    'Discord',
    keywords: ['connections', 'link', 'unlink'],
    conditional: true,
  ),
  SettingsEntry(
    _devicesPage,
    'Spotify',
    keywords: ['connections', 'link', 'unlink', 'music'],
    gate: SettingsGate.spotifyConfigured,
    conditional: true,
  ),
  SettingsEntry(
    _devicesPage,
    'Show my Spotify track',
    description: 'Shows your track even when you play on another device.',
    keywords: ['listening', 'music', 'now playing', 'song', 'spotify'],
    gate: SettingsGate.spotifyLinked,
    conditional: true,
  ),
  SettingsEntry(
    _devicesPage,
    'Devices',
    description: 'Everywhere this account is signed in.',
    keywords: ['sessions', 'sign out', 'logout', 'version'],
  ),
  SettingsEntry(
    _devicesPage,
    'Your data',
    description: 'A copy of what you wrote and uploaded.',
    keywords: [
      'export',
      'download my data',
      'archive',
      'backup',
      'portability',
    ],
  ),
  SettingsEntry(
    _devicesPage,
    'Download my data',
    description: 'Messages, reactions, saved items, notes and uploads.',
    keywords: ['export', 'archive', 'backup', 'portability'],
  ),
  SettingsEntry(
    _devicesPage,
    'Sign-in',
    description: "How you prove it's you on a new device.",
    keywords: ['2fa', 'two factor', 'totp', 'authenticator', 'security'],
  ),
  SettingsEntry(
    _devicesPage,
    'Password',
    description: 'Changing it signs out your other devices.',
    keywords: ['change password', 'security'],
  ),
  SettingsEntry(
    'appearance',
    'Theme',
    keywords: ['dark', 'light', 'colors', 'colours', 'mode'],
  ),
  SettingsEntry(
    'appearance',
    'High contrast',
    description: 'Stronger borders and text.',
    keywords: ['accessibility', 'contrast', 'theme'],
  ),
  SettingsEntry(
    'appearance',
    'Clock',
    description: 'System follows your device clock.',
    keywords: ['time', '24 hour', '12 hour'],
  ),
  SettingsEntry(
    'appearance',
    'Motion',
    description: 'System follows your device motion setting.',
    keywords: ['animation', 'reduce motion', 'accessibility'],
  ),
  SettingsEntry('appearance', 'Density', keywords: ['compact', 'spacing']),
  SettingsEntry(
    'appearance',
    'Thread lines',
    description: 'Join a run of messages from one person with a line.',
  ),
  SettingsEntry('appearance', 'Space between groups', keywords: ['spacing']),
  SettingsEntry(
    'appearance',
    'Interface scale',
    keywords: ['zoom', 'size', 'font size', 'text size', 'bigger', 'smaller'],
  ),
  SettingsEntry(
    'appearance',
    'Messages',
    description: 'How tight messages sit, and how far apart groups are.',
    keywords: ['compact', 'density'],
  ),
  SettingsEntry('appearance', 'Text and layout', keywords: ['font']),
  SettingsEntry(
    'notifications',
    'Show message text',
    keywords: ['preview', 'privacy', 'push'],
  ),
  SettingsEntry(
    'notifications',
    'Notification schedule',
    description: 'Only notify during the hours you set.',
    keywords: ['quiet hours', 'do not disturb', 'snooze'],
  ),
  SettingsEntry(
    'notifications',
    'Message, mention and error sounds',
    keywords: ['sound', 'chime', 'audio', 'mute'],
  ),
  SettingsEntry(
    'notifications',
    'Interface sounds',
    description: 'Soft cues for sending, joining and muting.',
    keywords: ['sound', 'send sound', 'mute sound', 'ringback', 'chime'],
  ),
  SettingsEntry(
    'notifications',
    'Haptics',
    description: 'Vibrate for taps, holds and alerts.',
    keywords: ['vibration', 'vibrate', 'haptic feedback'],
    conditional: true,
    available: _mobile,
  ),
  SettingsEntry(
    'notifications',
    'Dock module sounds',
    description: 'Lets modules play short sounds.',
  ),
  SettingsEntry(
    'notifications',
    'Notify me for',
    keywords: ['mentions', 'all messages', 'push'],
  ),
  SettingsEntry('notifications', 'When to notify'),
  SettingsEntry(
    'notifications',
    'Sounds',
    keywords: ['audio', 'haptics', 'vibration'],
  ),
  SettingsEntry(
    'voice',
    'Hold a key to talk',
    description: 'Hold the key to talk; your mic indicator stays on in calls.',
    keywords: ['push to talk', 'ptt', 'keybind', 'hotkey'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Shortcuts',
    keywords: ['keybind', 'hotkey', 'keyboard'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Mute shortcut',
    keywords: ['mute', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Deafen shortcut',
    keywords: ['deafen', 'hotkey', 'keybind', 'global', 'remap'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Reset shortcuts',
    keywords: ['default', 'keybind', 'hotkey'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    'voice',
    'Join with camera on',
    description: 'Calls still connect without a camera.',
    keywords: ['video', 'webcam'],
  ),
  SettingsEntry(
    'voice',
    'Share device audio',
    keywords: ['screen share audio', 'system audio'],
  ),
  SettingsEntry(
    'voice',
    'Pause video when minimised',
    description: 'Stops receiving video while the window is minimised.',
  ),
  SettingsEntry(
    'voice',
    'Join and leave sounds',
    description: 'Off automatically in busy calls.',
    keywords: ['sound', 'chime'],
  ),
  SettingsEntry('voice', 'Incoming call sound', keywords: ['ring', 'ringtone']),
  SettingsEntry('voice', 'Music while alone', keywords: ['hold music']),
  SettingsEntry(
    'voice',
    'Microphone',
    description: 'Your input level while you are in a call.',
    keywords: ['mic', 'input', 'level', 'gate', 'sensitivity', 'threshold'],
  ),
  SettingsEntry(
    'voice',
    'Speaker',
    keywords: ['output', 'headphones', 'headset', 'audio device'],
  ),
  SettingsEntry(
    'voice',
    'Watching',
    description: 'Video and screens from others.',
    keywords: ['video quality'],
  ),
  SettingsEntry('voice', 'Your camera', keywords: ['webcam', 'video']),
  SettingsEntry(
    'voice',
    'Screen share resolution',
    keywords: ['stream', 'quality', '1080p', '720p'],
  ),
  SettingsEntry(
    'voice',
    'Screen share frame rate',
    keywords: ['stream', 'fps', '60fps'],
  ),
  SettingsEntry(
    'voice',
    'Devices',
    description: 'What a call uses to hear, speak and show you.',
    keywords: ['mic', 'microphone', 'speaker', 'camera', 'input', 'output'],
  ),
  SettingsEntry(
    'voice',
    'Video quality',
    description: 'Lower it to save data, raise it to see more.',
  ),
  SettingsEntry('voice', 'Sharing and preview', keywords: ['screen share']),
  SettingsEntry('voice', 'Sounds', keywords: ['audio', 'chime']),
  SettingsEntry(
    'voice',
    'Noise suppression',
    description: 'Strong also removes keyboards, fans and room noise.',
    keywords: ['noise', 'background noise', 'keyboard', 'rnnoise', 'strong'],
    conditional: true,
    available: _inputGate,
  ),
  SettingsEntry(
    'performance',
    'Auto-download media',
    description: 'Whether images load as you scroll or wait for a tap.',
    keywords: ['data', 'images', 'download'],
  ),
  SettingsEntry(
    'performance',
    'Autoplay GIFs',
    description: 'Whether gifs move on their own.',
    keywords: ['gif', 'animation', 'animated'],
  ),
  SettingsEntry(
    'performance',
    'Link previews',
    description: 'Whether links get a preview card.',
    keywords: ['embed', 'unfurl', 'card'],
  ),
  SettingsEntry(
    'performance',
    'Attachment preview quality',
    description: 'How sharply attachments are drawn in messages.',
    keywords: ['images', 'resolution'],
  ),
  SettingsEntry(
    'performance',
    'Image cache',
    description: 'How much memory recent images may use.',
    keywords: ['memory', 'ram'],
  ),
  SettingsEntry(
    'performance',
    'Media',
    description: 'What loads and plays on its own.',
  ),
  SettingsEntry(
    'performance',
    'Storage',
    description: 'How much this device keeps around.',
    keywords: ['cache', 'disk', 'clear'],
  ),
  SettingsEntry(
    desktopPane,
    'Startup',
    description: 'What happens when the app opens.',
    keywords: ['boot', 'launch', 'login'],
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Start on login',
    description: 'Opens slim-m in the tray when you sign in.',
    keywords: ['autostart', 'startup', 'boot', 'tray'],
    conditional: true,
    available: _desktop,
  ),
  SettingsEntry(
    desktopPane,
    'Startup splash',
    description: 'How long the splash shows when the app opens.',
    keywords: ['startup', 'launch', 'loading'],
    available: _desktop,
  ),
  SettingsEntry(
    'performance',
    'History',
    description: 'How many messages load when you scroll back.',
  ),
  SettingsEntry(
    'performance',
    'Message page size',
    keywords: ['history', 'scrollback'],
  ),
  SettingsEntry(
    'blocked',
    'People you blocked',
    description: 'You stop seeing and hearing from them; they are not told.',
    keywords: ['block', 'unblock'],
  ),
  SettingsEntry(
    'report-status',
    'Reports you filed',
    description: 'Reports from this device, and whether each is still open.',
    keywords: ['report'],
  ),
  SettingsEntry(
    'report-status',
    'Check a report by ID',
    description: 'Paste the ID of a report from another device.',
  ),
  SettingsEntry(
    'troubleshooting',
    'This device',
    keywords: ['debug log', 'logs', 'diagnostics', 'bug'],
  ),
  SettingsEntry(
    'troubleshooting',
    'Call stats',
    description: 'Live video numbers for a call.',
    keywords: ['bitrate', 'fps', 'packet loss', 'latency', 'network'],
  ),
  SettingsEntry(
    'troubleshooting',
    'Connection test',
    description: 'Latency and speed to the server.',
    keywords: ['speed', 'ping', 'latency', 'lan', 'cloudflare', 'network'],
  ),
  SettingsEntry(
    'troubleshooting',
    'Last call audio',
    description: 'How the audio held up.',
    keywords: ['voice', 'static', 'jitter', 'packet loss', 'quality', 'call'],
  ),
  SettingsEntry(
    'troubleshooting',
    'Run setup again',
    description: 'Profile, notifications and voice, one step at a time.',
    keywords: ['onboarding', 'welcome', 'tour', 'first run', 'setup'],
  ),
  SettingsEntry(
    'about',
    'Automatic updates',
    description: 'Tell me at startup when a new version is available.',
    keywords: ['update', 'version'],
  ),
  SettingsEntry('about', 'Updates', keywords: ['version', 'changelog']),
];

bool _desktop() => isDesktopHost;

bool _mobile() => isIOSHost || isAndroidHost;

bool _inputGate() => isLinuxHost || isWindowsHost;

/// [entries] that exist here and sit on one of [paneIds].
List<SettingsEntry> settingsEntriesFor(
  Iterable<SettingsEntry> entries,
  Set<String> paneIds,
) => [
  for (final entry in entries)
    if (paneIds.contains(entry.pane) && (entry.available?.call() ?? true))
      entry,
];

/// [entries] matching [query], best first: a label starting with the query
/// beats a word in it, which beats a keyword, which beats the description.
List<SettingsEntry> searchSettings(
  String query,
  Iterable<SettingsEntry> entries,
) {
  final words = query.toLowerCase().trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) return const [];
  final scored = <(int, SettingsEntry)>[];
  for (final entry in entries) {
    var total = 0;
    for (final word in words) {
      final score = _score(word, entry);
      if (score == 0) {
        total = 0;
        break;
      }
      total += score;
    }
    if (total > 0) scored.add((total, entry));
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    return byScore != 0 ? byScore : a.$2.label.compareTo(b.$2.label);
  });
  return [for (final (_, entry) in scored) entry];
}

int _score(String word, SettingsEntry entry) {
  final label = entry.label.toLowerCase();
  if (label.startsWith(word)) return 100;
  if (_wordStarts(label, word)) return 80;
  for (final keyword in entry.keywords) {
    if (keyword.startsWith(word) || _wordStarts(keyword, word)) return 70;
  }
  if (label.contains(word)) return 50;
  if (entry.keywords.any((k) => k.contains(word))) return 40;
  if (entry.description?.toLowerCase().contains(word) ?? false) return 30;
  return 0;
}

bool _wordStarts(String text, String word) =>
    text.split(RegExp(r'[^a-z0-9]+')).any((part) => part.startsWith(word));
