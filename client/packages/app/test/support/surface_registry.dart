// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The routed screens under review, keyed by name, with the viewports each
/// one is pictured at. Shared by the screen snapshot test (does it fit?) and
/// the screen semantics gate (can a screen reader reach everything on it?),
/// so a screen registered here is checked both ways at once.
library;

import '../ui_snapshot_support.dart';
import '../features/voice/voice_snapshot_fixtures.dart' show dmChannelId;

/// The surfaces worth a picture: the route, and which viewports to render.
///
/// `channel` straddles every breakpoint it owns because width changes its
/// structure. A voice channel needs the identical breakpoint treatment - it
/// is the same shell, just a different `kind` - but it also needs its
/// controller pinned, or the body shows a real, unmocked auto-join that
/// settles into a blank frame long before this matrix pumps far enough to
/// see it fail; see `_shellStateSurfaces`'s own `voice` entry for that.
/// Each standalone screen adds the pair that brackets its *own* breakpoint
/// to a phone and a desktop render, rather than every screen sampling every
/// boundary: a screen with no 800px floor of its own gains nothing from
/// being rendered at 799 and 800.
const snapshotSurfaces = <String, ({String route, List<String> viewports})>{
  'channel': (
    route: '/channels/c-general',
    viewports: [
      'phone-portrait',
      'phone-landscape',
      'tablet-portrait',
      'desktop-narrow',
      'desktop',
      ...compactBracket,
      'expanded-999',
      'expanded-1000',
    ],
  ),
  // The default landing state right after sign-in, absent from this matrix until now.
  'no-channel-selected': (
    route: '/channels',
    viewports: [
      ...phoneAndDesktop,
      ...compactBracket,
      'expanded-999',
      'expanded-1000',
    ],
  ),
  // c-empty has no messages, which #general never does, so only it can show the transcript's offline-empty copy.
  'channel-offline-empty': (
    route: '/channels/c-empty',
    viewports: phoneAndDesktop,
  ),
  'onboarding': (
    route: '/join',
    viewports: [
      ...phoneAndDesktop,
      'stepper-467',
      'stepper-468',
      'onboarding-899',
      'onboarding-900',
    ],
  ),
  'sign-in': (
    route: '/sign-in',
    viewports: [...phoneAndDesktop, 'onboarding-899', 'onboarding-900'],
  ),
  'settings': (
    route: '/settings',
    viewports: [
      ...phoneAndDesktop,
      ...compactBracket,
      'settings-799',
      'settings-800',
    ],
  ),
  'space-settings': (
    route: '/settings/space',
    viewports: [
      ...phoneAndDesktop,
      ...compactBracket,
      'settings-799',
      'settings-800',
    ],
  ),
  'admin-roles': (
    route: '/settings/roles',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-invites': (
    route: '/settings/invites',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-reports': (
    route: '/settings/reports',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // The routed screen needs the channel as `extra`; channelSettingsFixtureRoute supplies #general.
  'channel-settings': (
    route: '/settings/channel',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-overwrites': (
    route: '/settings/permissions',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-emoji': (
    route: '/settings/emoji',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-removed-members': (
    route: '/settings/removed-members',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-analytics': (
    route: '/settings/analytics',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'debug-log': (
    route: '/settings/debug-log',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // The Dock's three levels; the third was a sheet over a modal until #1148.
  'admin-dock': (
    route: '/settings/dock',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-dock-module': (
    route: '/settings/dock/code-exec',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  'admin-dock-module-access': (
    route: '/settings/dock/code-exec/access',
    viewports: [...phoneAndDesktop, ...compactBracket],
  ),
  // The stacked-header bug only ever showed past kCompactWidth; the compact bracket proves it stays clean there too.
  'thread': (
    route: '/thread/c-thread',
    viewports: [
      ...phoneAndDesktop,
      ...compactBracket,
      'expanded-999',
      'expanded-1000',
    ],
  ),
  // No call open: dm-call-button-idle; -active-lit needs dmCallActivityProvider reporting a ring, which nothing here drives.
  'dm': (route: '/channels/$dmChannelId', viewports: phoneAndDesktop),
};
