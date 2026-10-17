// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [PhotoLibrary] over `photo_manager`, for iOS and Android only.
library;

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'photo_library.dart';

PhotoLibrary? createPhotoLibrary() {
  final phone =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  return phone ? _PluginPhotoLibrary() : null;
}

class _PluginPhotoLibrary implements PhotoLibrary {
  final Map<String, AssetEntity> _assets = {};

  static const _request = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.image,
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
      type: RequestType.image,
    );
    if (albums.isEmpty) return const [];
    final assets = await albums.first.getAssetListRange(start: 0, end: count);
    for (final asset in assets) {
      _assets[asset.id] = asset;
    }
    return [for (final asset in assets) RecentPhoto(asset.id)];
  }

  @override
  Future<Uint8List?> thumbnail(String id, int pixels) async =>
      _assets[id]?.thumbnailDataWithSize(ThumbnailSize.square(pixels));

  @override
  Future<PhotoOriginal?> original(String id) async {
    final file = await _assets[id]?.file;
    if (file == null) return null;
    return (bytes: await file.readAsBytes(), name: file.uri.pathSegments.last);
  }

  @override
  Future<void> manageLimited() =>
      PhotoManager.presentLimited(type: RequestType.image);
}
