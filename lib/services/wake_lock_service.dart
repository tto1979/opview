// wake lock toggle via platform channel
// enables/disables FLAG_KEEP_SCREEN_ON on the native side

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.tto1979.topview/wake_lock');

Future<void> setKeepScreenOn(bool enabled) async {
  try {
    await _channel.invokeMethod('setKeepScreenOn', enabled);
  } on PlatformException catch (_) {
    // best-effort — don't crash if the channel isn't available
  }
}
