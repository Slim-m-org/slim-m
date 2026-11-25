// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [PhotoLibrary] over `photo_manager`, for iOS and Android only.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../desktop/self_update/play_install.dart' show playBuild;
import 'file_source_io.dart';
import 'photo_library.dart';
import 'staged_attachment_model.dart';

/// Null in the Play build, whose bundle drops the photo permissions the strip needs (decision 0025).
PhotoLibrary? createPhotoLibrary({bool isPlayBuild = playBuild}) {
  if (isPlayBuild) return null;
  final phone =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  return phone ? _PluginPhotoLibrary() : null;
}

class _PluginPhotoLibrary implements PhotoLibrary {
  final Map<String, AssetEntity> _assets = {};

  static const _request = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  @override
  Future<PhotoAccess> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: _request,
    );
    return switch (state) {
      PermissionState.authorized => PhotoAccess.full,
      PermissionState.limited => PhotoAccess.limited,
      _ => PhotoAccess.denied,
    };
  }

  @override
  Future<List<RecentPhoto>> recent(int count) async {
    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.common,
    );
    if (albums.isEmpty) return const [];
    final assets = await albums.first.getAssetListRange(start: 0, end: count);
    for (final asset in assets) {
      _assets[asset.id] = asset;
    }
    return Future.wait([for (final asset in assets) _photoOf(asset)]);
  }

  Future<RecentPhoto> _photoOf(AssetEntity asset) async {
    final isVideo = asset.type == AssetType.video;
    return RecentPhoto(
      asset.id,
      isVideo: isVideo,
      bytes: isVideo ? await _sizeOf(asset) : null,
    );
  }

  Future<int?> _sizeOf(AssetEntity asset) async {
    try {
      return await asset.fileSize;
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.media,
        'read a library video size',
        error,
        stack,
      );
      return null;
    }
  }

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async =>
      _assets[id]?.thumbnailDataWithSize(ThumbnailSize.square(pixels));

  @override
  Future<FileSource?> original(String id) async {
    final File? file;
    try {
      file = await _assets[id]?.file;
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'read a library photo', error, stack);
      return null;
    }
    if (file == null) return null;
    return fileSourceOf(file, name: file.uri.pathSegments.last);
  }

  @override
  Future<void> clearCache() => PhotoManager.clearFileCache();

  @override
  Future<void> manageLimited() =>
      PhotoManager.presentLimited(type: RequestType.common);
}
