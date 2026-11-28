// downloads through the system download manager (Android), via MainActivity's channel

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.tto1979.topview/download');

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => message;
}

/// a queued download
class QueuedDownload {
  final int id;
  final String folder; // shown to the user, e.g. Download/topview
  final String name;

  const QueuedDownload(this.id, this.folder, this.name);

  String get path => '$folder/$name';
}

enum DownloadState { pending, running, paused, done, failed, gone }

class DownloadStatus {
  final DownloadState state;
  final int reason; // failed: HTTP status or DownloadManager.ERROR_*

  const DownloadStatus(this.state, [this.reason = 0]);

  bool get ended => state == DownloadState.done || state == DownloadState.failed || state == DownloadState.gone;
}

/// DownloadManager.STATUS_* -> state
DownloadState downloadStateOf(int status) => switch (status) {
      1 => DownloadState.pending,
      2 => DownloadState.running,
      4 => DownloadState.paused,
      8 => DownloadState.done,
      16 => DownloadState.failed,
      _ => DownloadState.pending,
    };

/// queue a download
Future<QueuedDownload> download(Uri url, String fileName) async {
  try {
    final r = await _channel.invokeMapMethod<String, dynamic>('download', {'url': url.toString(), 'name': fileName});
    return QueuedDownload((r?['id'] as num?)?.toInt() ?? -1, '${r?['folder'] ?? ''}', fileName);
  } on MissingPluginException {
    throw DownloadException('not supported on this platform');
  } on PlatformException catch (e) {
    throw DownloadException(e.message ?? e.code);
  }
}

Future<DownloadStatus> downloadStatus(int id) async {
  try {
    final r = await _channel.invokeMapMethod<String, dynamic>('status', {'id': id});
    if (r == null) return const DownloadStatus(DownloadState.gone);
    return DownloadStatus(downloadStateOf((r['status'] as num?)?.toInt() ?? 0), (r['reason'] as num?)?.toInt() ?? 0);
  } catch (_) {
    return const DownloadStatus(DownloadState.gone);
  }
}

/// the system's list of downloads (their files, progress and errors)
Future<void> openDownloads() async {
  try {
    await _channel.invokeMethod('openDownloads');
  } catch (_) {
    // no downloads app: nothing to open
  }
}
