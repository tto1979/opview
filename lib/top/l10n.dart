// strings for the drives & settings pages: Chinese (Traditional) or English, by the phone's language
// (setting names and descriptions come translated from the device)

import 'dart:ui' show PlatformDispatcher;

class T {
  static bool zh = PlatformDispatcher.instance.locale.languageCode == 'zh';

  static String _t(String zhText, String enText) => zh ? zhText : enText;

  static String get menu => _t('行程與設定', 'Drives & settings');
  static String get drives => _t('行程', 'Drives');
  static String get settings => _t('設定', 'Settings');
  static String get back => _t('即時畫面', 'Live view');
  static String get connecting => _t('連線到裝置…', 'Connecting to the device…');
  static String get noDevice => _t(
      '還沒找到裝置。手機要和裝置在同一個 Wi-Fi（例如裝置連著手機熱點），或直接輸入裝置的 IP。',
      'No device found yet. The phone has to be on the same Wi-Fi as the device (e.g. the phone\'s hotspot), '
          'or enter the device\'s IP.');
  static String get deviceIp => _t('裝置 IP', 'Device IP');
  static String get connect => _t('連線', 'Connect');
  static String get changeIp => _t('變更 IP', 'Change IP');
  static String get retry => _t('重試', 'Retry');
  static String get noApi => _t(
      '裝置沒有回應。TOP：在 TOP 設定頁打開「啟用 opview」。dragonpilot：打開 dashy。',
      'The device didn\'t answer. TOP: turn on "Enable opview" in the TOP settings. dragonpilot: turn on dashy.');
  static String get probeUnreachable => _t(
      '手機連不到這個 IP。確認 IP 正確、手機和裝置在同一個網路；有些路由器會隔離連線的裝置（訪客網路、AP 隔離），可以改用手機熱點。',
      'The phone can\'t reach this IP. Check the IP and that both are on the same network; some routers isolate '
          'their clients (guest networks, AP isolation), the phone\'s hotspot avoids that.');
  static String get probeRefused => _t(
      '裝置有回應，但 opview 服務沒在執行。確認 TOP 設定頁「啟用 opview」已打開，而且 TOP 已更新到最新的 main-0.11.1。',
      'The device answers, but the opview service isn\'t running. Turn on "Enable opview" in the TOP settings and '
          'update TOP to the latest main-0.11.1.');
  static String get probeNotFound => _t(
      '裝置上的 TOP 版本還沒有 opview API，請更新到最新的 main-0.11.1。',
      'The TOP version on the device has no opview API yet: update to the latest main-0.11.1.');
  static String get networkError => _t('連不到裝置', 'Can\'t reach the device');
  static String get pairingTitle => _t('輸入配對碼', 'Enter the pairing code');
  static String get pairingHint => _t(
      'TOP 設定頁「啟用 opview」說明最後一行的 6 位數字（C4：opview pairing code 卡片）。',
      'The 6 digits at the end of "Enable opview" in the TOP settings (C4: the opview pairing code card).');
  static String get pairingWrong => _t('配對碼不對', 'Wrong pairing code');
  static String get pairAgain => _t('重新配對', 'Pair again');
  static String get cancel => _t('取消', 'Cancel');
  static String get ok => _t('確定', 'OK');
  static String get search => _t('搜尋', 'Search');
  static String get noDrives => _t('沒有行程', 'No drives');
  static String get driving => _t('行駛中', 'Driving');
  static String get parked => _t('停車中', 'Parked');
  static String get download => _t('下載', 'Download');
  static String get onroadNoDownload => _t('行駛中無法下載', 'Not available while driving');
  static String get notPlayable => _t('沒有可播放的影片', 'No playable video');

  // onroad HUD (same words as the device's TOP HUD)
  static String get near => _t('接近', 'Near');
  static String get km => _t('公里', 'km');
  static String get meter => _t('公尺', 'm');
  static String get mile => _t('英里', 'mi');
  static String get foot => _t('英尺', 'ft');
  static String get ahead => _t('前方', 'AHEAD');
  static String get speedSign => _t('時速', 'SPEED');
  static String get limitSign => _t('速限', 'LIMIT');
  static String get max => _t('最大', 'MAX');
  static String personality(int i) => const [['積極', 'Aggressive'], ['標準', 'Standard'], ['從容', 'Relaxed']][i][zh ? 0 : 1];

  static String segments(int n) => _t('$n 段', '$n segments');
  static String minutes(int n) => _t('$n 分鐘', '$n min');
  static String segment(int i) => _t('第 ${i + 1} 段', 'Segment ${i + 1}');
  static String downloading(String where) => _t('開始下載，存到 $where', 'Downloading to $where');
  static String downloadFailed(String e) => _t('下載失敗：$e', 'Download failed: $e');
  static String loadFailed(String e) => _t('讀取失敗：$e', 'Couldn\'t load: $e');

  static String fileLabel(String name) {
    const zhLabels = {
      'qcamera.ts': '預覽影片',
      'fcamera.hevc': '前鏡頭原始畫質',
      'ecamera.hevc': '廣角鏡頭',
      'dcamera.hevc': '車內鏡頭',
      'qlog.zst': '精簡紀錄',
      'qlog': '精簡紀錄',
      'rlog.zst': '完整紀錄',
      'rlog': '完整紀錄',
    };
    const enLabels = {
      'qcamera.ts': 'Preview video',
      'fcamera.hevc': 'Road camera, full quality',
      'ecamera.hevc': 'Wide camera',
      'dcamera.hevc': 'Driver camera',
      'qlog.zst': 'Small log',
      'qlog': 'Small log',
      'rlog.zst': 'Full log',
      'rlog': 'Full log',
    };
    return (zh ? zhLabels : enLabels)[name] ?? name;
  }
}
