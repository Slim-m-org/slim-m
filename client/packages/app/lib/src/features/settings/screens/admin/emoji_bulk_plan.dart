// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a picked zip's decoded entries into the emoji uploads they plan,
/// before any network request happens.
///
/// Split from the widget that drives it (`emoji_add_dialog.dart`) so the
/// derivation is checkable on its own: directories and non-images skipped,
/// and a suggested name taken from the file's stem and sanitized through
/// [normalizeEmojiName]. Whether that name is usable or already taken is the
/// review step's call, so a file is never dropped for its name.
library;

import 'package:archive/archive.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;

import 'emoji_name.dart';

/// The extensions the server actually stores an emoji as: the inline subset
/// of `media::ALLOWED_TYPES` in `crates/slimm-server/src/media.rs`.
const acceptedEmojiExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp'];

/// Most entries one zip may hold before it is refused unread, so a zip bomb
/// of a million empty names costs a header count rather than a decode.
const int maxZipEntries = 2000;

/// Most uncompressed bytes of images one zip may declare before any is inflated.
const int maxZipUncompressedBytes = 64 * 1024 * 1024;

/// A zip refused unread for being over [maxZipEntries] or [maxZipUncompressedBytes].
class ZipTooLargeException implements Exception {
  const ZipTooLargeException();
}

/// One entry decoded from a zip, narrowed from `archive`'s own `ArchiveFile`
/// to the three fields [planEmojiZip] needs, so a test can hand it a
/// synthetic list without decoding real zip bytes.
class ZipEntryData {
  const ZipEntryData({
    required this.path,
    required List<int> bytes,
    this.isFile = true,
    this.declaredSize,
  }) : _bytes = bytes,
       _inflate = null;

  /// An image whose bytes are inflated when [bytes] is first read, so a plan
  /// that refuses it never pays for it.
  const ZipEntryData.deferred({
    required this.path,
    required int size,
    required List<int> Function() inflate,
  }) : _bytes = null,
       _inflate = inflate,
       isFile = true,
       declaredSize = size;

  /// The entry's full path inside the archive, `/`-separated regardless of
  /// the platform that wrote it.
  final String path;
  final List<int>? _bytes;
  final List<int> Function()? _inflate;

  /// False for a directory entry, which carries no bytes worth planning.
  final bool isFile;

  /// The entry's uncompressed size when the bytes were left empty or not yet
  /// inflated, so an oversized image is still reported as one. A header can
  /// understate it, so the inflated length is what the plan finally trusts.
  final int? declaredSize;

  /// Throws for an entry that will not inflate (corrupt, encrypted, unsupported).
  List<int> get bytes => _bytes ?? _inflate!();

  int get size => declaredSize ?? bytes.length;
}

/// Decodes [zipBytes] into its entries.
///
/// Only an entry [planEmojiZip] could queue can be inflated, and only once the
/// plan queues it: a non-image, or an image already over [maxPlannedEmojiBytes]
/// by its declared size, keeps empty bytes, and the rest wait to be read, so a
/// zip bomb costs a header read and a pack past [maxPlannedEmojiCount] images
/// inflates no more than that many.
///
/// `ZipDecoder` is lenient: bytes that are not a zip at all decode to an
/// empty list rather than throwing, which [planEmojiZip] then reports as
/// "nothing to upload" - still a refusal, never a crash. A handful of
/// malformed-but-zip-shaped inputs can still throw (an [ArchiveException] or
/// a [FormatException]); callers catch those the same way. An entry that only
/// fails to inflate is refused on its own by [planEmojiZip].
List<ZipEntryData> decodeEmojiZipEntries(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  if (archive.length > maxZipEntries) throw const ZipTooLargeException();
  var declared = 0;
  for (final file in archive) {
    if (_wanted(file)) declared += file.size;
  }
  if (declared > maxZipUncompressedBytes) throw const ZipTooLargeException();
  return [for (final file in archive) _entryFor(file)];
}

bool _wanted(ArchiveFile file) =>
    file.isFile &&
    acceptedEmojiExtensions.contains(_extension(_baseName(file.name))) &&
    file.size <= maxPlannedEmojiBytes;

ZipEntryData _entryFor(ArchiveFile file) {
  if (!_wanted(file)) {
    return ZipEntryData(
      path: file.name,
      bytes: const [],
      isFile: file.isFile,
      declaredSize: file.size,
    );
  }
  return ZipEntryData.deferred(
    path: file.name,
    size: file.size,
    inflate: () => file.content,
  );
}

/// One image [planEmojiZip] queues for upload.
class PlannedEmojiUpload {
  const PlannedEmojiUpload({
    required this.fileName,
    required this.name,
    required this.bytes,
  });

  /// The entry's own file name (no directory), shown in progress and in any
  /// failure the server later reports against it.
  final String fileName;

  /// The file's stem, sanitized: the name the review starts from.
  ///
  /// May be empty or past [maxEmojiNameLength], which the review flags for the
  /// admin to fix rather than the plan refusing the file.
  final String name;
  final List<int> bytes;
}

/// One entry [planEmojiZip] refused before any request was made, and why.
class SkippedZipEntry {
  const SkippedZipEntry({required this.fileName, required this.reason});
  final String fileName;
  final String reason;
}

/// What a zip turned into: what will be uploaded, and what already could
/// not be, without a single request having been made yet.
class EmojiZipPlan {
  const EmojiZipPlan({required this.uploads, required this.skipped});
  final List<PlannedEmojiUpload> uploads;
  final List<SkippedZipEntry> skipped;
}

/// The largest single image this plans to upload, matching the server's own
/// `MAX_IMAGE_BYTES` (`crates/slimm-server/src/emoji.rs`) so an oversized
/// file is refused here rather than after a wasted round trip.
const int maxPlannedEmojiBytes = 1024 * 1024;

/// The most images one zip will queue, so a pathological archive cannot turn
/// one pick into thousands of sequential uploads.
const int maxPlannedEmojiCount = 200;

/// Most images one `POST /emoji/bulk` request may carry, matching the
/// server's own `MAX_BULK_IMAGES` (`crates/slimm-server/src/emoji/bulk.rs`).
const int maxBulkRequestCount = 50;

/// Most decoded bytes one `POST /emoji/bulk` request's images may total,
/// matching the server's own `MAX_BULK_TOTAL_BYTES`.
const int maxBulkRequestBytes = 20 * 1024 * 1024;

/// Splits [uploads] into the requests the server will accept: at most
/// [maxBulkRequestCount] images and at most [maxBulkRequestBytes] decoded
/// bytes in any one chunk.
///
/// This is why a 200-image pack (over [maxBulkRequestCount]) still imports:
/// it becomes a handful of `POST /emoji/bulk` calls instead of one call per
/// image, each charged once against the upload rate limit rather than once
/// per image - the actual defect a 200-image pack used to hit. Every planned
/// upload already passed [maxPlannedEmojiBytes] (1 MB, well under the 20 MB
/// per-chunk cap), so no image is ever dropped by this split, only grouped.
List<List<PlannedEmojiUpload>> chunkPlannedEmojiUploads(
  List<PlannedEmojiUpload> uploads,
) {
  final chunks = <List<PlannedEmojiUpload>>[];
  var current = <PlannedEmojiUpload>[];
  var currentBytes = 0;

  for (final upload in uploads) {
    final size = upload.bytes.length;
    final overCount = current.length >= maxBulkRequestCount;
    final overBytes =
        current.isNotEmpty && currentBytes + size > maxBulkRequestBytes;
    if (overCount || overBytes) {
      chunks.add(current);
      current = <PlannedEmojiUpload>[];
      currentBytes = 0;
    }
    current.add(upload);
    currentBytes += size;
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// Turns decoded zip [entries] into what will be uploaded and what is
/// already refused, without making any request.
EmojiZipPlan planEmojiZip(List<ZipEntryData> entries) {
  final uploads = <PlannedEmojiUpload>[];
  final skipped = <SkippedZipEntry>[];

  for (final entry in entries) {
    final fileName = _candidateFileName(entry);
    if (fileName == null) continue;

    var reason = _rejection(entry, fileName, uploads.length);
    final read = reason == null ? _readBytes(entry) : null;
    reason ??= read?.reason;
    if (reason != null) {
      skipped.add(SkippedZipEntry(fileName: fileName, reason: reason));
      continue;
    }
    uploads.add(
      PlannedEmojiUpload(
        fileName: fileName,
        name: normalizeEmojiName(_stem(fileName)),
        bytes: read!.bytes!,
      ),
    );
  }
  return EmojiZipPlan(uploads: uploads, skipped: skipped);
}

/// The entry's file name, or null for directories and hidden or sidecar files that are not worth reporting.
String? _candidateFileName(ZipEntryData entry) {
  if (!entry.isFile || _isMacosJunk(entry.path)) return null;
  final fileName = _baseName(entry.path);
  if (fileName.isEmpty || fileName.startsWith('.')) return null;
  return fileName;
}

/// Why the entry cannot become an upload before it is inflated, or null.
String? _rejection(ZipEntryData entry, String fileName, int plannedCount) {
  if (!acceptedEmojiExtensions.contains(_extension(fileName))) {
    return 'not a PNG, JPEG, GIF or WEBP image';
  }
  if (plannedCount >= maxPlannedEmojiCount) {
    return 'more than $maxPlannedEmojiCount images at once';
  }
  return _sizeRefusal(entry.size);
}

String? _sizeRefusal(int size) {
  if (size == 0) return 'the file is empty';
  if (size > maxPlannedEmojiBytes) return 'larger than 1 MB';
  return null;
}

/// The entry's bytes, or why they cannot be queued, judged by their real
/// length rather than the header's.
({List<int>? bytes, String? reason}) _readBytes(ZipEntryData entry) {
  final List<int> bytes;
  try {
    bytes = entry.bytes;
  } catch (error, stack) {
    reportFailure(LogTag.media, 'inflate an emoji zip entry', error, stack);
    return (bytes: null, reason: 'could not be read from the zip');
  }
  return (bytes: bytes, reason: _sizeRefusal(bytes.length));
}

/// Whether [path] is macOS's own AppleDouble sidecar junk (`__MACOSX/` and
/// its `._name` shadow files), which a zip built on macOS carries alongside
/// every real entry and which decode as garbage if sniffed as images.
bool _isMacosJunk(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.startsWith('__MACOSX/') ||
      normalized.contains('/__MACOSX/');
}

/// The path's final segment: a zip entry may sit inside a folder
/// (`icons/party_blob.gif`), and only the file name names the emoji.
String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}

/// The lowercase extension without its dot, or the empty string if there is
/// none.
String _extension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

/// The file name with its extension stripped: the part Discord-style naming
/// takes the emoji's name from (`party_blob.gif` -> `party_blob`).
String _stem(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
