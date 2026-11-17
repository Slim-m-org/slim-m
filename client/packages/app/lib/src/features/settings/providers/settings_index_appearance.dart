// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Appearance pane's half of the settings search index; see
/// `settings_index.dart`.
library;

import 'settings_index.dart';

const appearanceSettingsIndex = <SettingsEntry>[
  SettingsEntry(
    'appearance',
    'Badges in member list',
    keywords: ['members', 'badge', 'modules', 'level'],
  ),
  SettingsEntry(
    'appearance',
    'Sections on profiles',
    keywords: ['profile', 'level', 'xp', 'modules'],
  ),
  SettingsEntry(
    'appearance',
    'Theme',
    keywords: [
      'dark',
      'light',
      'colors',
      'colours',
      'mode',
      'halloween',
      'store',
      'default',
    ],
  ),
  SettingsEntry(
    'appearance',
    'Browse themes',
    keywords: [
      'store',
      'gallery',
      'import',
      'export',
      'publish',
      'custom',
      'recent',
    ],
    conditional: true,
  ),
  SettingsEntry(
    'appearance',
    'Follow Space default',
    keywords: ['theme', 'space default', 'server theme'],
    conditional: true,
    gate: SettingsGate.spaceDefaultTheme,
  ),
  SettingsEntry(
    'appearance',
    'High contrast',
    description: 'Stronger borders and text.',
    keywords: ['accessibility', 'contrast', 'theme'],
  ),
  SettingsEntry(
    'appearance',
    'Background',
    description: 'A picture behind the chat, kept on this device.',
    keywords: ['wallpaper', 'image', 'picture', 'vignette', 'blur', 'dim'],
  ),
  SettingsEntry(
    'appearance',
    'Clock',
    keywords: ['time', '24 hour', '12 hour'],
  ),
  SettingsEntry(
    'appearance',
    'Motion',
    keywords: ['animation', 'reduce motion', 'accessibility'],
  ),
  SettingsEntry('appearance', 'Density', keywords: ['compact', 'spacing']),
  SettingsEntry('appearance', 'Thread lines'),
  SettingsEntry('appearance', 'Space between groups', keywords: ['spacing']),
  SettingsEntry(
    'appearance',
    'Interface scale',
    keywords: ['zoom', 'size', 'font size', 'text size', 'bigger', 'smaller'],
  ),
  SettingsEntry('appearance', 'Messages', keywords: ['compact', 'density']),
  SettingsEntry('appearance', 'Text and layout', keywords: ['font']),
];
