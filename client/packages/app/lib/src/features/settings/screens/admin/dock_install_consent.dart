// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The consent step before a module is installed or updated
/// (docs/decisions/0067-module-install-consent.md): what it can do in plain
/// words, then an explicit yes. A module from an unreviewed source needs the
/// admin to tick that they understand; a verified one is a lighter list and
/// the Install press is the yes.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'dock_host_access_card.dart';
import 'dock_limits_card.dart';
import 'dock_schedule_card.dart' show dockEveryWords;

/// Official-registry modules are verified; every community source is not.
bool dockIsVerified(String? source) => source == null || source == 'official';

/// The capabilities [manifest] asks for that the install being replaced did
/// not, with a first install asking for all of them.
List<String> newConsentCapabilities(
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) {
  final had = installed?.approvedCapabilities ?? const <String>[];
  return [
    for (final capability in grantableHostCapabilities(manifest.capabilities))
      if (!had.contains(capability) ||
          _widened(capability, manifest, installed))
        capability,
  ];
}

/// Whether an update takes back an approved power the admin has not seen:
/// every host power after a new build, new hosts for `net.fetch`, a changed
/// schedule, a new `events` subscription, a wider `data.store`, or a hook at
/// any new version. Mirrors the server's rules in `http/dock/capabilities.rs`.
bool dockNeedsReapproval(
  String capability,
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) {
  if (installed == null) return false;
  final newBuild = installed.artifactSha256 != manifest.artifact.sha256;
  return switch (capability) {
    'message.post' || 'log.read' => newBuild,
    // The installed record carries no hooks to compare, so a new version asks again.
    'interceptors' ||
    'permission.hook' => newBuild || installed.version != manifest.version,
    api.kNetFetchCapability =>
      newBuild ||
          !dockSameHosts(
            installed.networkHosts,
            manifest.network?.hosts ?? const [],
          ),
    'schedule' =>
      newBuild || dockScheduleChanges(manifest, installed).isNotEmpty,
    'events' =>
      newBuild || dockNewSubscriptions(manifest, installed).isNotEmpty,
    'data.store' => newBuild || dockDataWidened(manifest, installed),
    // The installed record does not carry the module's words, so an update always asks again.
    'call.audio' => true,
    _ => false,
  };
}

/// `message.post` is left to the access card's own "approved again" switch.
bool _widened(
  String capability,
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) =>
    capability != 'message.post' &&
    installed != null &&
    installed.approvedHostCapabilities.contains(capability) &&
    dockNeedsReapproval(capability, manifest, installed);

/// Event kinds [manifest] subscribes to that the installed build did not.
List<String> dockNewSubscriptions(
  api.DockManifest manifest,
  api.InstalledDockModule installed,
) => [
  for (final kind in manifest.subscriptions)
    if (!installed.subscriptions.contains(kind)) kind,
];

/// Whether [manifest] asks for more data room than the installed build had.
bool dockDataWidened(
  api.DockManifest manifest,
  api.InstalledDockModule installed,
) {
  final wanted = manifest.dataSchema;
  if (wanted == null) return false;
  final had = installed.dataSchema;
  return had == null || !had.covers(wanted);
}

/// Plain sentences for what an update changes about a module's reach or
/// timer, so the consent sheet can say "now every 5 minutes, was weekly".
List<String> dockConsentChanges(
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) {
  if (installed == null) return const [];
  final hosts = manifest.network?.hosts ?? const <String>[];
  final approved = installed.approvedHostCapabilities;
  final newSubscriptions = dockNewSubscriptions(manifest, installed);
  return [
    if (approved.contains(api.kNetFetchCapability) &&
        !dockSameHosts(installed.networkHosts, hosts))
      'Now reaches ${hosts.join(', ')}, was ${installed.networkHosts.join(', ')}.',
    if (approved.contains('schedule'))
      ...dockScheduleChanges(manifest, installed),
    if (approved.contains('events') && newSubscriptions.isNotEmpty)
      'Now listens for ${newSubscriptions.join(', ')}.',
    if (approved.contains('data.store') && dockDataWidened(manifest, installed))
      'Now asks for more room in its data store.',
    if (installed.artifactSha256 != manifest.artifact.sha256 &&
        approved.any(_reaskedOnNewBuild.contains))
      'This is a new build of the module code.',
  ];
}

const _reaskedOnNewBuild = {
  api.kNetFetchCapability,
  'schedule',
  'events',
  'data.store',
  'log.read',
  'interceptors',
  'permission.hook',
  'call.audio',
};

/// The sentences for schedule entries that are new or run at another interval.
List<String> dockScheduleChanges(
  api.DockManifest manifest,
  api.InstalledDockModule installed,
) => [
  for (final next in manifest.schedules)
    switch (installed.schedules
        .where((s) => s.command == next.command)
        .firstOrNull) {
      null => 'Now runs ${next.command} ${dockEveryWords(next.everyMinutes)}.',
      final was when was.everyMinutes != next.everyMinutes =>
        '${next.command} now runs ${dockEveryWords(next.everyMinutes)}, '
            'was ${dockEveryWords(was.everyMinutes)}.',
      _ => null,
    },
].nonNulls.toList(growable: false);

/// Whether two host lists name the same hosts, in any order.
bool dockSameHosts(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

/// Whether the private-network yes [installed] holds still stands for [manifest].
bool dockLocalNetworkCarries(
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
  Set<String> approved,
) =>
    (manifest.network?.local ?? false) &&
    approved.contains(api.kNetFetchCapability) &&
    installed != null &&
    installed.localNetworkApproved &&
    dockSameHosts(installed.networkHosts, manifest.network!.hosts);

/// Whether pressing Install should stop at the consent step first.
bool dockNeedsConsent({
  required List<String> newCapabilities,
  required bool verified,
  required bool firstInstall,
}) => newCapabilities.isNotEmpty || (firstInstall && !verified);

/// A "Verified" mark for a module from the official registry: the icon alone,
/// named by its tooltip and semantics label so a row stays on one line.
///
/// [tapToShow] also opens the tooltip on a tap. That is an owner exception to
/// desktop-vs-mobile.md "never a tooltip on touch" (owner, 2026-11-02): the
/// consent sheet shows only the badge, and a finger cannot hover. The sentence
/// is also the semantics label, so the tooltip is never the only carrier.
/// Rows leave it off so a tap on the badge still opens the row.
class DockVerifiedBadge extends StatelessWidget {
  const DockVerifiedBadge({
    super.key,
    this.message = 'Verified',
    this.tapToShow = false,
  });

  final String message;
  final bool tapToShow;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final badge = Tooltip(
      message: message,
      triggerMode: tapToShow ? TooltipTriggerMode.tap : null,
      child: Semantics(
        label: message,
        child: ExcludeSemantics(
          child: Icon(
            AppIcons.verified,
            size: AppSizes.icon16,
            color: tokens.accent,
          ),
        ),
      ),
    );
    if (!tapToShow) return badge;
    return AppTouchHitArea(alignment: Alignment.centerLeft, child: badge);
  }
}

/// Resolves true once the admin agrees, false when they back out or close it.
///
/// [title] and [intro] replace the headline and the line above the list, and
/// [confirmLabel] and [cancelLabel] rename the two buttons.
Future<bool> showDockInstallConsent(
  BuildContext context, {
  required api.DockManifest manifest,
  required List<String> capabilities,
  required bool verified,
  required bool isUpdate,
  bool localNetwork = false,
  List<String> changes = const [],
  String? title,
  String? intro,
  String? confirmLabel,
  String? cancelLabel,
}) async {
  final agreed = await showAppSheet<bool>(
    context,
    scrolls: true,
    builder: (context) => _ConsentSheet(
      manifest: manifest,
      capabilities: capabilities,
      verified: verified,
      isUpdate: isUpdate,
      localNetwork: localNetwork,
      title: title,
      intro: intro,
      changes: changes,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
    ),
  );
  return agreed ?? false;
}

class _ConsentSheet extends StatefulWidget {
  const _ConsentSheet({
    required this.manifest,
    required this.capabilities,
    required this.verified,
    required this.isUpdate,
    required this.localNetwork,
    required this.title,
    required this.intro,
    required this.changes,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final api.DockManifest manifest;

  /// What an update changed about the module's reach or timer.
  final List<String> changes;
  final bool localNetwork;
  final String? title;
  final String? intro;
  final String? confirmLabel;
  final String? cancelLabel;
  final List<String> capabilities;
  final bool verified;
  final bool isUpdate;

  @override
  State<_ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends State<_ConsentSheet> {
  bool _understood = false;

  /// Hearing a call reaches people other than the admin, so even a verified module needs the tick (decision 0105).
  bool get _needsTick =>
      widget.capabilities.contains(dockCallAudioCapability) ||
      (!widget.verified && widget.capabilities.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final verb = widget.isUpdate ? 'Update' : 'Install';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(child: SingleChildScrollView(child: _details(tokens, verb))),
          const SizedBox(height: AppSpacing.s16),
          if (_needsTick) ...[
            _acknowledgement(tokens),
            const SizedBox(height: AppSpacing.s16),
          ],
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: widget.cancelLabel ?? 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: widget.confirmLabel ?? verb,
                  variant: AppButtonVariant.primary,
                  disabled: _needsTick && !_understood,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _details(AppTokens tokens, String verb) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.title ?? '$verb ${widget.manifest.name}?',
        style: AppText.body.copyWith(
          color: tokens.textPrimary,
          fontWeight: AppWeights.semi,
        ),
      ),
      const SizedBox(height: AppSpacing.s8),
      _standing(tokens),
      const SizedBox(height: AppSpacing.s12),
      if (widget.capabilities.isNotEmpty) ...[
        Text(
          widget.intro ??
              (widget.isUpdate
                  ? 'This version asks for new access. It can:'
                  : 'This module can:'),
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        const SizedBox(height: AppSpacing.s8),
        for (final change in widget.changes)
          _CapabilityLine(text: change, verified: false),
        for (final capability in widget.capabilities)
          _CapabilityLine(
            text: dockCapabilityWarning(
              capability,
              details: dockCapabilityDetails(widget.manifest, capability),
            )!,
            verified: widget.verified,
          ),
        if (widget.localNetwork &&
            widget.capabilities.contains(api.kNetFetchCapability))
          _CapabilityLine(
            text: dockLocalNetworkWarning,
            verified: widget.verified,
          ),
        if (widget.capabilities.contains(dockCallAudioCapability) &&
            widget.manifest.callAudio != null)
          _CallAudioWords(words: widget.manifest.callAudio!),
      ] else
        Text(
          'It runs code on your server with no access to your space.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      const SizedBox(height: AppSpacing.s8),
      Text(
        DockLimitsCard.summary(widget.manifest.runtime.limits),
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    ],
  );

  Widget _standing(AppTokens tokens) {
    if (widget.verified) {
      final room = AppTouchTargets.of(context)
          ? (AppSizes.rowTouch - AppSizes.icon16) / 2
          : 0.0;
      return Padding(
        padding: EdgeInsets.symmetric(vertical: room),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: DockVerifiedBadge(
            message: 'From the official slim-addons registry.',
            tapToShow: true,
          ),
        ),
      );
    }
    return AppCallout(
      child: Text(
        'Not verified. slim-m has not reviewed this module.',
        style: AppText.body.copyWith(color: tokens.warnText),
      ),
    );
  }

  Widget _acknowledgement(AppTokens tokens) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _understood = !_understood),
    child: Row(
      children: [
        AppToggle(
          value: _understood,
          onChanged: (v) => setState(() => _understood = v),
          semanticLabel: 'I understand what this module can do',
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: Text(
            'I understand what this module can do',
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    ),
  );
}

class _CapabilityLine extends StatelessWidget {
  const _CapabilityLine({required this.text, required this.verified});

  final String text;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            verified ? AppIcons.info : AppIcons.warning,
            size: AppSizes.icon16,
            color: verified ? tokens.textSecondary : tokens.warnText,
          ),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: AppText.body.copyWith(color: tokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The module's own words about the calls it hears, as everyone in a call will see them.
class _CallAudioWords extends StatelessWidget {
  const _CallAudioWords({required this.words});

  final api.DockCallAudio words;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      key: const ValueKey('call-audio-words'),
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: AppCallout(
        tone: AppCalloutTone.warn,
        icon: AppIcons.callAudio,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'In the module\'s own words. slim-m cannot check them.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text('What it does: ${words.purpose}'),
            const SizedBox(height: AppSpacing.s4),
            Text('What it keeps: ${words.keeps}'),
          ],
        ),
      ),
    );
  }
}
