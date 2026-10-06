// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the composer's Apps button opens: the installed apps this caller
/// may launch (from `GET /modules/apps`), each a tap away from being posted
/// into the channel as its interactive, shared surface via
/// [api.SlimmApiMessages.launchAppMessage].
///
/// Nothing here names a module: it lists whatever discovery returns and
/// launches whatever was tapped, per docs/decisions/0021-modules-and-the-dock's
/// module-agnostic principle. [launchApp] is the shared launch path, reused by
/// the composer's `/name` alias so a launch means the same thing either way.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../ids.dart';
import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/app_launch.dart';
import '../providers/message_extras.dart';
import '../providers/providers.dart';
import '../routing/routes.dart';

/// Launches [app] into [channelId]: posts the message, then applies it to the
/// local store and extras cache exactly as sending a poll does, so the surface
/// appears at once without waiting for the echo. [onError] receives a
/// human-readable message on an API failure; nothing is posted then. Returns
/// whether the launch succeeded, so a caller that typed the launch (the `/name`
/// alias) can keep the text to retry on failure and clear it only on success.
Future<bool> launchApp({
  required WidgetRef ref,
  required String channelId,
  required api.App app,
  void Function(String message)? onError,
}) async {
  try {
    final sent = await ref
        .read(apiProvider)
        .launchAppMessage(
          channelId: channelId,
          id: newMessageId(),
          moduleId: app.moduleId,
          command: app.command,
        );
    final store = await ref.read(storeProvider.future);
    await store.applyMessage(sent);
    ref.read(messageExtrasProvider.notifier).applyMessage(sent);
    return true;
  } on api.ApiException catch (e) {
    onError?.call(describeApiFailure('launch ${app.name}', e));
    return false;
  } catch (_) {
    onError?.call('Could not launch ${app.name}.');
    return false;
  }
}

/// Opens the apps picker for [channelId]. [onError] is forwarded to [launchApp]
/// so a failed launch surfaces where the composer shows its command errors.
///
/// Launches go through the caller's [ref], not the sheet's: the sheet is gone by the time the request returns.
///
/// The body is its own [Consumer] rather than reading [ref] straight from the
/// caller: the sheet is a separate Overlay entry, not that caller's
/// descendant, so a watch bound to the caller's own element would never
/// rebuild the sheet once shown, leaving a slow fetch spinning forever.
Future<void> showAppLauncherSheet(
  BuildContext context,
  WidgetRef ref,
  String channelId, {
  void Function(String message)? onError,
}) {
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => Consumer(
      builder: (context, sheetRef, _) {
        final tokens = Theme.of(sheetContext).extension<AppTokens>()!;
        final apps = sheetRef.watch(appLaunchProvider);
        final canManageServer = sheetRef
            .watch(myPermissionsProvider)
            .hasPermission(Perm.manageServer);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              0,
              AppSpacing.s12,
              AppSpacing.s12,
            ),
            // Empty is hand-rendered below: its copy depends on permission.
            child: AppAsyncView<List<api.App>>(
              value: AppAsyncState(data: apps.valueOrNull, error: apps.error),
              center: false,
              errorMessage: 'Could not load your apps.',
              onRetry: () => sheetRef.invalidate(appLaunchProvider),
              data: (context, list) {
                if (list.isEmpty) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s16,
                          vertical: AppSpacing.s8,
                        ),
                        child: Text(
                          // Only an admin can act on this, so only an admin is told to.
                          canManageServer
                              ? 'No apps installed yet.'
                              : 'No apps installed. Ask an admin to install '
                                    'one from the Dock.',
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                      if (canManageServer)
                        AppListRow(
                          label: 'Open the Dock',
                          leading: Icon(
                            AppIcons.dock,
                            size: AppSizes.icon16,
                            color: tokens.textSecondary,
                          ),
                          trailing: ExcludeSemantics(
                            child: Icon(
                              AppIcons.chevronRight,
                              size: AppSizes.icon16,
                              color: tokens.textSecondary,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            context.push(Routes.adminDock);
                          },
                        ),
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final app in list)
                      AppListRow(
                        label: app.name,
                        subtitle: app.description,
                        leading: Icon(
                          AppIcons.dock,
                          size: AppSizes.icon16,
                          color: tokens.textSecondary,
                        ),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(
                            launchApp(
                              ref: ref,
                              channelId: channelId,
                              app: app,
                              onError: onError,
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    ),
  );
}
