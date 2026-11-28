// device API for drives, playback, downloads and settings
//
// TOP: webrtcd port 5001, needs the device's pairing code
//      (top/system/opview_api in tto1979/openpilot)
// dragonpilot: dashy port 5088, same paths and JSON, no pairing, no /api/routes

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const topPort = 5001;
const dashyPort = 5088;
const tokenHeader = 'X-Opview-Token';

const _timeout = Duration(seconds: 8);
const _probeTimeout = Duration(seconds: 4);
// first /api/settings builds the car list on the device
const _settingsTimeout = Duration(seconds: 40);

final _segmentRe = RegExp(r'^(.+)--(\d+)$');

enum ApiFlavor { top, dashy }

/// what the TOP port answered when looking for the API
enum Probe {
  ok,
  notFound, // something answers on 5001, without the opview API (TOP not updated, or not TOP)
  refused, // the device is there, nothing listens on 5001 (opview off, webrtcd not running)
  unreachable, // no answer at all (wrong IP, other network, router isolates clients)
  other,
}

class ApiException implements Exception {
  final int status; // 0: no response
  final String message;
  final String? code;
  final Probe? probe; // no_api: what the TOP port answered
  final String detail; // no_api: what each port answered, for the user to report

  ApiException(this.status, this.message, {this.code, this.probe, this.detail = ''});

  bool get unpaired => status == 401;
  bool get onroad => code == 'onroad';
  bool get noApi => code == 'no_api';

  @override
  String toString() => message;
}

class DeviceInfo {
  final ApiFlavor flavor;
  final bool isOffroad;
  final String dongleId;
  final String version;
  final String deviceType;

  const DeviceInfo({
    required this.flavor,
    required this.isOffroad,
    this.dongleId = '',
    this.version = '',
    this.deviceType = '',
  });

  factory DeviceInfo.fromInit(Map<String, dynamic> j) {
    final top = j['top'];
    if (top is Map) {
      return DeviceInfo(
        flavor: ApiFlavor.top,
        isOffroad: j['isOffroad'] != false,
        dongleId: '${top['dongle_id'] ?? ''}',
        version: '${top['version'] ?? ''}',
        deviceType: '${top['device_type'] ?? ''}',
      );
    }
    return DeviceInfo(flavor: ApiFlavor.dashy, isOffroad: j['isOffroad'] != false);
  }
}

// -- settings --

class SettingItem {
  final String key;
  final String type;
  final String title;
  final String description; // HTML (<br>, <b>, <h4>)
  final dynamic value;
  final List<String> options;
  final num minVal;
  final num maxVal;
  final num step;
  final String suffix;
  final bool enabled;
  final String? disabledReason;

  const SettingItem({
    required this.key,
    required this.type,
    required this.title,
    this.description = '',
    this.value,
    this.options = const [],
    this.minVal = 0,
    this.maxVal = 0,
    this.step = 1,
    this.suffix = '',
    this.enabled = true,
    this.disabledReason,
  });

  factory SettingItem.fromJson(Map<String, dynamic> j) {
    final reason = j['disabled_reason'];
    return SettingItem(
      key: '${j['key']}',
      type: '${j['type']}',
      title: '${j['title'] ?? j['key']}',
      description: '${j['description'] ?? ''}',
      value: j.containsKey('current_value') ? j['current_value'] : j['default'],
      options: (j['options'] as List?)?.map((o) => '$o').toList() ?? const [],
      minVal: (j['min_val'] as num?) ?? 0,
      maxVal: (j['max_val'] as num?) ?? 0,
      step: (j['step'] as num?) ?? 1,
      suffix: '${j['suffix'] ?? ''}',
      enabled: j['enabled'] != false,
      disabledReason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}

class SettingSection {
  final String title;
  final List<SettingItem> items;

  const SettingSection(this.title, this.items);

  static List<SettingSection> listFromJson(dynamic data) {
    final sections = (data is Map ? data['settings'] : null) as List? ?? const [];
    return [
      for (final s in sections.whereType<Map>())
        SettingSection(
          '${s['title'] ?? ''}',
          [
            for (final i in (s['settings'] as List? ?? const []).whereType<Map>())
              SettingItem.fromJson(i.cast<String, dynamic>()),
          ],
        ),
    ];
  }
}

// -- drives --

class Segment {
  final String name; // <route>--<index>
  final int index;
  final Map<String, int>? files; // file name -> bytes, null until listed
  final int size;

  const Segment({required this.name, required this.index, this.files, this.size = 0});

  bool get playable => files == null || files!.containsKey('qcamera.ts');
}

class RouteInfo {
  final String route;
  final String start; // 'YYYY-MM-DD HH:MM', device local time
  final int duration; // seconds
  final int size; // bytes, 0 if unknown
  final List<Segment> segments;

  const RouteInfo({
    required this.route,
    required this.start,
    required this.duration,
    required this.size,
    required this.segments,
  });

  bool get playable => segments.any((s) => s.playable);

  factory RouteInfo.fromJson(Map<String, dynamic> j) {
    final segments = [
      for (final s in (j['segments'] as List? ?? const []).whereType<Map>())
        Segment(
          name: '${s['name']}',
          index: (s['index'] as num?)?.toInt() ?? 0,
          files: (s['files'] as Map?)?.map((k, v) => MapEntry('$k', (v as num).toInt())),
          size: (s['size'] as num?)?.toInt() ?? 0,
        ),
    ]..sort((a, b) => a.index.compareTo(b.index));
    return RouteInfo(
      route: '${j['route']}',
      start: '${j['start'] ?? ''}',
      duration: (j['duration'] as num?)?.toInt() ?? segments.length * 60,
      size: (j['size'] as num?)?.toInt() ?? 0,
      segments: segments,
    );
  }
}

/// dashy has no /api/routes: group the log root's segment folders into drives
List<RouteInfo> routesFromFiles(dynamic data) {
  final files = (data is Map ? data['files'] : null) as List? ?? const [];
  final byRoute = <String, List<Segment>>{};
  final starts = <String, String>{};
  for (final f in files.whereType<Map>()) {
    if (f['is_dir'] != true) continue;
    final m = _segmentRe.firstMatch('${f['name']}');
    if (m == null) continue;
    final route = m.group(1)!;
    byRoute.putIfAbsent(route, () => []).add(Segment(name: '${f['name']}', index: int.parse(m.group(2)!)));
    final mtime = '${f['mtime'] ?? ''}';
    final first = starts[route];
    if (first == null || mtime.compareTo(first) < 0) starts[route] = mtime;
  }
  final routes = [
    for (final e in byRoute.entries)
      RouteInfo(
        route: e.key,
        start: starts[e.key] ?? '',
        duration: e.value.length * 60,
        size: 0,
        segments: e.value..sort((a, b) => a.index.compareTo(b.index)),
      ),
  ];
  routes.sort((a, b) => b.start.compareTo(a.start));
  return routes;
}

// -- client --

class DeviceApi {
  final String host;
  final String language; // Accept-Language, e.g. 'zh-TW'
  final http.Client _client;

  ApiFlavor flavor = ApiFlavor.top;
  String? token;
  DeviceInfo? info;

  DeviceApi(this.host, {this.language = 'en', http.Client? client}) : _client = client ?? http.Client();

  int get port => flavor == ApiFlavor.top ? topPort : dashyPort;
  bool get needsPairing => flavor == ApiFlavor.top;
  bool get hasRouteApi => flavor == ApiFlavor.top;

  /// pairing codes are kept per device
  String get deviceKey => (info?.dongleId.isNotEmpty ?? false) ? info!.dongleId : host;

  Uri uri(String path, [Map<String, String>? query]) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
        queryParameters: (query == null || query.isEmpty) ? null : query,
      );

  /// for URLs handed to a player or the download manager, which can't add headers
  Uri _withToken(String path, [Map<String, String>? query]) {
    final q = {...?query};
    if (needsPairing && token != null) q['token'] = token!;
    return uri(path, q);
  }

  /// find which API the device has: TOP first, then dashy
  Future<DeviceInfo> connect() async {
    final details = <String>[];
    Probe? topProbe;
    for (final candidate in [ApiFlavor.top, ApiFlavor.dashy]) {
      flavor = candidate;
      Probe probe;
      String what;
      try {
        final r = await _client.get(uri('/api/init'), headers: _headers()).timeout(_probeTimeout);
        final data = r.statusCode == 200 ? _decode(r) : null;
        final found = data is Map ? DeviceInfo.fromInit(data.cast<String, dynamic>()) : null;
        // dragonpilot's webrtcd on 5001 has no /api/init, so a TOP reply here is always TOP
        if (found != null && (candidate != ApiFlavor.top || found.flavor == ApiFlavor.top)) {
          flavor = found.flavor;
          info = found;
          return found;
        }
        probe = Probe.notFound;
        what = 'HTTP ${r.statusCode}';
      } on TimeoutException {
        probe = Probe.unreachable;
        what = 'timeout';
      } catch (e) {
        final text = '$e';
        probe = classifyError(text);
        what = text.length > 120 ? text.substring(0, 120) : text;
      }
      topProbe ??= probe;
      details.add('$host:$port  $what');
    }
    flavor = ApiFlavor.top;
    throw ApiException(0, 'no api', code: 'no_api', probe: topProbe, detail: details.join('\n'));
  }

  Future<List<SettingSection>> settings() async =>
      SettingSection.listFromJson(await _json('GET', '/api/settings', timeout: _settingsTimeout));

  /// returns the value the device saved
  Future<dynamic> setParam(String key, dynamic value) async {
    final data = await _json('POST', '/api/settings/params/$key', body: {'value': value});
    return data is Map ? data['value'] : value;
  }

  Future<List<RouteInfo>> routes() async {
    if (hasRouteApi) {
      final data = await _json('GET', '/api/routes');
      final list = (data is Map ? data['routes'] : null) as List? ?? const [];
      return [for (final r in list.whereType<Map>()) RouteInfo.fromJson(r.cast<String, dynamic>())];
    }
    return routesFromFiles(await _json('GET', '/api/files', query: {'path': '/'}));
  }

  /// files of one segment, name -> bytes
  Future<Map<String, int>> segmentFiles(Segment segment) async {
    if (segment.files != null) return segment.files!;
    final data = await _json('GET', '/api/files', query: {'path': segment.name});
    final files = (data is Map ? data['files'] : null) as List? ?? const [];
    return {
      for (final f in files.whereType<Map>())
        if (f['is_dir'] != true) '${f['name']}': (f['size'] as num?)?.toInt() ?? 0,
    };
  }

  /// fresh driving state (downloads are off while driving on TOP)
  Future<bool> isOffroad() async {
    final data = await _json('GET', '/api/init');
    return !(data is Map && data['isOffroad'] == false);
  }

  /// checks the pairing code with a cheap authenticated request
  Future<void> checkPairing() async {
    await _json('GET', '/api/files', query: {'path': '/'});
  }

  Uri routeManifest(String route) => _withToken('/api/manifest.m3u8', {'route': route});
  Uri fileManifest(String file) => _withToken('/api/manifest.m3u8', {'file': file});
  Uri downloadUrl(String file) => _withToken('/download/$file');

  Map<String, String> _headers() => {
        'Accept-Language': language,
        if (needsPairing && token != null) tokenHeader: token!,
      };

  Future<dynamic> _json(String method, String path,
      {Map<String, String>? query, Object? body, Duration timeout = _timeout}) async {
    final headers = _headers();
    http.Response r;
    try {
      if (method == 'POST') {
        headers['Content-Type'] = 'application/json';
        r = await _client.post(uri(path, query), headers: headers, body: jsonEncode(body)).timeout(timeout);
      } else {
        r = await _client.get(uri(path, query), headers: headers).timeout(timeout);
      }
    } on TimeoutException {
      throw ApiException(0, 'timeout', code: 'timeout');
    } catch (e) {
      throw ApiException(0, '$e', code: 'network');
    }
    final data = _decode(r);
    if (r.statusCode != 200) {
      final error = data is Map ? data['error'] : null;
      throw ApiException(
        r.statusCode,
        error is String && error.isNotEmpty ? error : 'HTTP ${r.statusCode}',
        code: data is Map ? data['code'] as String? : null,
      );
    }
    return data;
  }

  static dynamic _decode(http.Response r) {
    if (r.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

/// pairing codes per device (dongle id, or host before it's known)
class PairingStore {
  static String _key(String device) => 'opview_pairing_$device';

  static Future<String?> load(String device) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(device));
  }

  static Future<void> save(String device, String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(device), code);
  }

  static Future<void> clear(String device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(device));
  }
}

/// a socket error -> what it means for finding the device
Probe classifyError(String error) {
  final e = error.toLowerCase();
  if (e.contains('refused')) return Probe.refused;
  if (e.contains('timed out') || e.contains('timeout') || e.contains('no route') || e.contains('unreachable')) {
    return Probe.unreachable;
  }
  return Probe.other;
}

/// phone locale -> Accept-Language the device understands (zh-TW / zh-CN, else the language)
String acceptLanguage(String languageCode, {String? scriptCode, String? countryCode}) {
  if (languageCode == 'zh') {
    final simplified = scriptCode == 'Hans' || countryCode == 'CN' || countryCode == 'SG';
    return simplified ? 'zh-CN' : 'zh-TW';
  }
  if (languageCode == 'pt') return 'pt-BR';
  return languageCode;
}

/// description HTML -> plain text with line breaks
String htmlToText(String html) {
  var s = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<h\d[^>]*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</h\d>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
}
