// downloads through the system download manager (Android), via MainActivity's channel

import 'package:flutter/services.dart';

const _channel = MethodChannel('org.dragonpilot.opview/download');

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => message;
}

/// queue a download, returns the folder it lands in (shown to the user)
Future<String> download(Uri url, String fileName) async {
  try {
    return await _channel.invokeMethod<String>('download', {'url': url.toString(), 'name': fileName}) ?? '';
  } on MissingPluginException {
    throw DownloadException('not supported on this platform');
  } on PlatformException catch (e) {
    throw DownloadException(e.message ?? e.code);
  }
}

/// Android API level, 0 elsewhere
Future<int> androidSdk() async {
  try {
    return await _channel.invokeMethod<int>('sdkInt') ?? 0;
  } catch (_) {
    return 0;
  }
}
