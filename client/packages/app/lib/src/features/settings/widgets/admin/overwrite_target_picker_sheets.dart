// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared picker sheets: [ChannelPickerSheet] for `channel_permissions_screen.dart`'s
/// channel choice, and [RolePickerSheet] for adding a grid column.
///
/// The role sheet watches its provider from inside the sheet
/// rather than being handed a pre-read list: an autoDispose `FutureProvider`
/// read once with `ref.read` outside a listener registers no subscriber, so
/// it can be (and reliably is) torn down mid-fetch, leaving the sheet
/// permanently empty with no spinner and no error. Watching keeps the
/// provider alive for exactly as long as the sheet is open, the same shape
/// `role_assign_sheet.dart` already uses for its member list.
///
/// The channel sheet takes an already-resolved list instead: its caller
/// awaits a one-shot `store.watchChannels().first` rather than a live
/// provider, so there is nothing here for it to watch.
///
/// Each carries a one-line heading, matching every sibling "choose one"
/// sheet (`camera_source_sheet.dart`, `screen_source_sheet.dart`) - these
/// these used to open straight into a bare row list, which read as a
/// floating pill on desktop and gave no on-screen confirmation of what was
/// being picked on phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../channels/providers/dms.dart' show dmChannelKind;

/// The ceiling a resolved list may grow to before it scrolls internally
/// rather than pushing the sheet past the window - never a size the sheet
/// is forced to regardless of how few rows there are; see
/// [_PickerList]'s own doc.
const _pickerListMaxHeightFraction = 0.6;

const _headingPadding = EdgeInsets.fromLTRB(
  AppSpacing.s16,
  0,
  AppSpacing.s16,
  AppSpacing.s12,
);

class ChannelPickerSheet extends StatelessWidget {
  const ChannelPickerSheet({super.key, required this.channels});

  final List<Channel> channels;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: _headingPadding,
            child: Text('Choose a channel', style: AppText.heading),
          ),
          _PickerList(
            children: [
              // A DM carries no overwrites or webhooks; it is a person, not a channel.
              for (final c in channels.where((c) => c.kind != dmChannelKind))
                AppListRow(
                  leading: Icon(
                    c.kind == 'voice' ? AppIcons.voice : AppIcons.hash,
                  ),
                  label: c.name,
                  onTap: () => Navigator.of(context).pop(c),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What [RolePickerSheet] pops when the member row is chosen instead of a role.
const chooseMemberInstead = Object();

class RolePickerSheet extends ConsumerWidget {
  const RolePickerSheet({super.key, this.offerMember = false});

  /// Adds a leading "A member..." row, so adding to the grid is one sheet.
  final bool offerMember;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = ref.watch(rolesProvider);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: _headingPadding,
            child: Text(
              offerMember ? 'Add a role or member' : 'Choose a role',
              style: AppText.heading,
            ),
          ),
          AppAsyncView(
            value: AppAsyncState(data: roles.valueOrNull, error: roles.error),
            errorMessage: 'Could not load roles.',
            onRetry: () => ref.invalidate(rolesProvider),
            emptyMessage: 'No roles yet.',
            isEmpty: (list) => list.isEmpty,
            data: (context, list) => _PickerList(
              children: [
                if (offerMember)
                  AppListRow(
                    leading: const Icon(AppIcons.account),
                    label: 'A member...',
                    onTap: () => Navigator.of(context).pop(chooseMemberInstead),
                  ),
                for (final role in list)
                  AppListRow(
                    leading: const Icon(AppIcons.shield),
                    label: role.name,
                    onTap: () => Navigator.of(context).pop(role),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A resolved list of rows: sized to its content, up to
/// [_pickerListMaxHeightFraction] of the window, past which it scrolls
/// internally rather than growing further. `shrinkWrap: true` is what makes
/// two or three rows read as two or three rows rather than a card with most
/// of it empty - the previous fixed-fraction `SizedBox` forced this height
/// regardless of row count, the inverse of `avatar-crop-sheet`'s own
/// previously-shipped "too tall for the window" bug: this one was "too tall
/// for too little content."
class _PickerList extends StatelessWidget {
  const _PickerList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight:
          MediaQuery.sizeOf(context).height * _pickerListMaxHeightFraction,
    ),
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      children: children,
    ),
  );
}
