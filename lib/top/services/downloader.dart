// drive downloads: the app fetches the file itself (same connection as the API and the player) into its cache,
// then MainActivity puts it into Download/topview. The system's download manager runs in another process on its
// own network choice and stalled on the device's LAN address.

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const _channel = MethodChannel('com.tto1979.topview/download');

/// no data for this long: give up instead of hanging
const _stallTimeout = Duration(seconds: 30);

class DownloadException implements Exception {
  final String message;
  final int? status; // the device's HTTP status
  final bool cancelled;
  final bool timedOut;

  DownloadException(this.message, {this.status, this.cancelled = false, this.timedOut = false});

  @override
  String toString() => message;
}

typedef SaveDownload = Future<String> Function(String tempPath, String name);

Future<String> _cacheDir() async {
  try {
    return await _channel.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
  } on MissingPluginException {
    return Directory.systemTemp.path;
  }
}

Future<String> _saveToDownloads(String tempPath, String name) async {
  try {
    return await _channel.invokeMethod<String>('saveToDownloads', {'path': tempPath, 'name': name}) ?? '';
  } on MissingPluginException {
    throw DownloadException('not supported on this platform');
  } on PlatformException catch (e) {
    throw DownloadException(e.message ?? e.code);
  }
}

/// one download at a time, cancellable
class FileDownloader {
  final http.Client Function() _newClient;
  final Future<String> Function() _tempDir;
  final SaveDownload _save;

  http.Client? _active;
  bool _cancelled = false;

  FileDownloader({http.Client Function()? newClient, Future<String> Function()? tempDir, SaveDownload? save})
      : _newClient = newClient ?? http.Client.new,
        _tempDir = tempDir ?? _cacheDir,
        _save = save ?? _saveToDownloads;

  bool get busy => _active != null;

  /// downloads [url] as [name], returns where it was saved; [onProgress] gets bytes so far and the total (-1 unknown)
  Future<String> fetch(Uri url, String name, {void Function(int received, int total)? onProgress}) async {
    _cancelled = false;
    final client = _newClient();
    _active = client;
    final temp = File('${await _tempDir()}/$name.part');
    IOSink? sink;
    try {
      final response = await client.send(http.Request('GET', url)).timeout(_stallTimeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw DownloadException('HTTP ${response.statusCode}', status: response.statusCode);
      }
      final total = response.contentLength ?? -1;
      sink = temp.openWrite();
      var received = 0;
      await for (final chunk in response.stream.timeout(_stallTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      sink = null;
      if (total > 0 && received != total) throw DownloadException('incomplete: $received of $total bytes');
      return await _save(temp.path, name);
    } on DownloadException {
      rethrow;
    } on TimeoutException {
      throw DownloadException('timeout', timedOut: true);
    } catch (e) {
      if (_cancelled) throw DownloadException('cancelled', cancelled: true);
      throw DownloadException('$e');
    } finally {
      await sink?.close();
      _active = null;
      client.close();
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // the cache is cleaned up by the system anyway
      }
    }
  }

  void cancel() {
    _cancelled = true;
    _active?.close();
  }
}

/// the phone's downloads (its files app)
Future<void> openDownloads() async {
  try {
    await _channel.invokeMethod('openDownloads');
  } catch (_) {
    // no downloads app: nothing to open
  }
}
