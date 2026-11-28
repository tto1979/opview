import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/services/downloader.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response _err(int status, Map<String, Object> body) => http.Response(jsonEncode(body), status, headers: _json);

const _topInit = {
  'isOffroad': true,
  'top': {'api': 1, 'pairing': true, 'device_type': 'tici', 'version': '0.11.1', 'dongle_id': 'abc123'},
};

const _settings = {
  'settings': [
    {
      'title': 'TOP',
      'settings': [
        {'key': 'NNFF', 'type': 'toggle_item', 'title': '開啟 NNFF 控制器', 'description': 'a<br>b', 'current_value': true, 'enabled': true},
        {'key': 'CarModel', 'type': 'select_item', 'title': '車型', 'current_value': '[-Not selected-]',
          'options': ['[-Not selected-]', 'TOYOTA_RAV4_TSS2'], 'enabled': true},
      ],
    },
    {
      'title': '速限控制',
      'settings': [
        {'key': 'SpeedLimitValueOffset', 'type': 'spin_button_item', 'title': 'Offset', 'current_value': 5,
          'min_val': -30, 'max_val': 30, 'step': 1, 'suffix': ' km/h', 'enabled': false, 'disabled_reason': '行駛中無法變更'},
        {'key': 'dp_lat_offset', 'type': 'double_spin_button_item', 'title': 'dashy item', 'default': 0.5, 'step': 0.05},
      ],
    },
  ],
};

void main() {
  group('connect', () {
    test('TOP on 5001', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async {
        expect(req.url.port, topPort);
        return _ok(_topInit);
      }));
      final info = await api.connect();
      expect(api.flavor, ApiFlavor.top);
      expect(api.needsPairing, isTrue);
      expect(api.hasRouteApi, isTrue);
      expect(info.dongleId, 'abc123');
      expect(api.deviceKey, 'abc123');
    });

    test('falls back to dashy on 5088', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async {
        if (req.url.port == topPort) return http.Response('Not Found', 404);
        return _ok({'dp_dev_dashy': 1, 'isOffroad': false});
      }));
      final info = await api.connect();
      expect(api.flavor, ApiFlavor.dashy);
      expect(api.port, dashyPort);
      expect(api.needsPairing, isFalse);
      expect(info.isOffroad, isFalse);
      expect(api.deviceKey, '10.0.0.2');
    });

    test('no API anywhere', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async => throw http.ClientException('Connection refused')));
      await expectLater(
        api.connect(),
        throwsA(isA<ApiException>()
            .having((e) => e.noApi, 'noApi', isTrue)
            .having((e) => e.probe, 'probe', Probe.refused)
            .having((e) => e.detail, 'detail', contains('10.0.0.2:5001'))),
      );
    });

    test('old TOP without the API', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async {
        if (req.url.port == topPort) return http.Response('Not Found', 404);
        throw http.ClientException('Connection refused');
      }));
      await expectLater(api.connect(), throwsA(isA<ApiException>().having((e) => e.probe, 'probe', Probe.notFound)));
    });
  });

  group('requests', () {
    test('pairing code and language go with every request', () async {
      final seen = <http.Request>[];
      final api = DeviceApi('10.0.0.2', language: 'zh-TW', client: MockClient((req) async {
        seen.add(req);
        return req.url.path == '/api/init' ? _ok(_topInit) : _ok(_settings);
      }));
      await api.connect();
      api.token = '123456';
      await api.settings();
      expect(seen.last.headers[tokenHeader], '123456');
      expect(seen.last.headers['Accept-Language'], 'zh-TW');
    });

    test('player and download URLs carry the code', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async => _ok(_topInit)));
      await api.connect();
      api.token = '123456';
      expect(api.routeManifest('0000002a--b4c8e1f2d3').toString(),
          'http://10.0.0.2:5001/api/manifest.m3u8?route=0000002a--b4c8e1f2d3&token=123456');
      expect(api.downloadUrl('0000002a--b4c8e1f2d3--1/fcamera.hevc').toString(),
          'http://10.0.0.2:5001/download/0000002a--b4c8e1f2d3--1/fcamera.hevc?token=123456');
    });

    test('settings parse', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async => _ok(_settings)));
      final sections = await api.settings();
      expect(sections.map((s) => s.title), ['TOP', '速限控制']);
      final nnff = sections[0].items[0];
      expect(nnff.type, 'toggle_item');
      expect(nnff.value, isTrue);
      expect(sections[0].items[1].options, ['[-Not selected-]', 'TOYOTA_RAV4_TSS2']);
      final offset = sections[1].items[0];
      expect(offset.minVal, -30);
      expect(offset.suffix, ' km/h');
      expect(offset.enabled, isFalse);
      expect(offset.disabledReason, '行駛中無法變更');
      final dashy = sections[1].items[1];
      expect(dashy.value, 0.5); // dashy sends default, no current_value
      expect(dashy.enabled, isTrue);
    });

    test('write sends the value, errors come back with the device\'s message', () async {
      late Map<String, dynamic> body;
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        if (req.url.path.endsWith('/NNFF')) return _err(409, {'error': '請在裝置上變更，或熄火後再改。'});
        return _ok({'status': 'success', 'key': 'IsMetric', 'value': true});
      }));
      expect(await api.setParam('IsMetric', true), isTrue);
      expect(body, {'value': true});
      await expectLater(
        api.setParam('NNFF', false),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.message, 'message', '請在裝置上變更，或熄火後再改。')),
      );
    });

    test('unpaired and onroad', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async {
        if (req.url.path == '/api/routes') return _err(401, {'error': 'pairing code required', 'code': 'unpaired'});
        return _err(409, {'error': '行駛中無法使用。', 'code': 'onroad'});
      }));
      await expectLater(api.routes(), throwsA(isA<ApiException>().having((e) => e.unpaired, 'unpaired', isTrue)));
      await expectLater(api.checkPairing(), throwsA(isA<ApiException>().having((e) => e.onroad, 'onroad', isTrue)));
    });

    test('TOP routes', () async {
      final api = DeviceApi('10.0.0.2', client: MockClient((req) async => _ok({
            'routes': [
              {
                'route': 'r1', 'start': '2026-11-27 08:01', 'duration': 120, 'size': 2000, 'playable': true,
                'segments': [
                  {'name': 'r1--1', 'index': 1, 'size': 1000, 'files': {'fcamera.hevc': 1000}},
                  {'name': 'r1--0', 'index': 0, 'size': 1000, 'files': {'qcamera.ts': 100, 'fcamera.hevc': 900}},
                ],
              },
            ],
          })));
      final routes = await api.routes();
      expect(routes.single.segments.map((s) => s.index), [0, 1]);
      expect(routes.single.segments[0].playable, isTrue);
      expect(routes.single.segments[1].playable, isFalse);
      expect(routes.single.playable, isTrue);
    });
  });

  test('dashy folders grouped into drives', () {
    final routes = routesFromFiles({
      'path': '',
      'files': [
        {'name': 'b--0', 'is_dir': true, 'mtime': '2026-11-27 09:00', 'size': 0},
        {'name': 'a--1', 'is_dir': true, 'mtime': '2026-11-26 08:02', 'size': 0},
        {'name': 'a--0', 'is_dir': true, 'mtime': '2026-11-26 08:01', 'size': 0},
        {'name': 'boot', 'is_dir': true, 'mtime': '2026-11-27 10:00', 'size': 0},
        {'name': 'x--3.txt', 'is_dir': false, 'mtime': '2026-11-27 10:00', 'size': 3},
      ],
    });
    expect(routes.map((r) => r.route), ['b', 'a']);
    expect(routes[1].segments.map((s) => s.name), ['a--0', 'a--1']);
    expect(routes[1].start, '2026-11-26 08:01');
    expect(routes[1].duration, 120);
    expect(routes[1].segments[0].files, isNull); // listed when needed
  });

  test('classifyError', () {
    expect(classifyError('SocketException: Connection refused (OS Error: Connection refused, errno = 111)'), Probe.refused);
    expect(classifyError('SocketException: No route to host (OS Error: No route to host, errno = 113)'), Probe.unreachable);
    expect(classifyError('Connection timed out'), Probe.unreachable);
    expect(classifyError('Failed host lookup'), Probe.other);
  });

  group('FileDownloader', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('topview_test'));
    tearDown(() async => dir.delete(recursive: true));

    FileDownloader downloader(http.StreamedResponse Function() respond, {List<int>? saved}) => FileDownloader(
          newClient: () => MockClient.streaming((request, body) async => respond()),
          tempDir: () async => dir.path,
          save: (path, name) async {
            saved?.addAll(await File(path).readAsBytes());
            return 'Download/topview/$name';
          },
        );

    test('downloads into the cache, saves, cleans up', () async {
      final saved = <int>[];
      final progress = <int>[];
      final d = downloader(() => http.StreamedResponse(Stream.fromIterable([[1, 2], [3]]), 200, contentLength: 3), saved: saved);
      final where = await d.fetch(Uri.parse('http://10.0.0.2:5001/download/a--1/rlog.zst'), 'a--1_rlog.zst',
          onProgress: (got, total) => progress.add(got));
      expect(where, 'Download/topview/a--1_rlog.zst');
      expect(saved, [1, 2, 3]);
      expect(progress, [2, 3]);
      expect(dir.listSync(), isEmpty);
      expect(d.busy, isFalse);
    });

    test('the device refusing', () async {
      final d = downloader(() => http.StreamedResponse(Stream.fromIterable([utf8.encode('{"code": "onroad"}')]), 409));
      await expectLater(
        d.fetch(Uri.parse('http://10.0.0.2:5001/download/a--1/rlog.zst'), 'a--1_rlog.zst'),
        throwsA(isA<DownloadException>().having((e) => e.status, 'status', 409)),
      );
      expect(dir.listSync(), isEmpty);
    });

    test('cut off', () async {
      final d = downloader(() => http.StreamedResponse(Stream.fromIterable([[1, 2, 3]]), 200, contentLength: 10));
      await expectLater(
        d.fetch(Uri.parse('http://10.0.0.2:5001/download/a--1/rlog.zst'), 'a--1_rlog.zst'),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('incomplete'))),
      );
    });
  });

  test('download reasons', () {
    T.zh = false;
    expect(T.downloadReason(409), 'not available while driving');
    expect(T.downloadReason(500), 'HTTP 500');
  });

  test('rlogOf', () {
    expect(rlogOf({'qcamera.ts': 1, 'rlog.zst': 2}), 'rlog.zst');
    expect(rlogOf({'rlog.bz2': 2}), 'rlog.bz2');
    expect(rlogOf({'rlog': 2}), 'rlog');
    expect(rlogOf({'qlog.zst': 1}), isNull);
  });

  test('htmlToText', () {
    expect(htmlToText('<b>WARNING</b><br><br>text &amp; more'), 'WARNING\n\ntext & more');
    expect(htmlToText('intro<br><h4>Title</h4><br>body'), 'intro\n\nTitle\n\nbody');
  });

  test('acceptLanguage', () {
    expect(acceptLanguage('zh', scriptCode: 'Hant', countryCode: 'TW'), 'zh-TW');
    expect(acceptLanguage('zh', countryCode: 'HK'), 'zh-TW');
    expect(acceptLanguage('zh', scriptCode: 'Hans'), 'zh-CN');
    expect(acceptLanguage('zh', countryCode: 'CN'), 'zh-CN');
    expect(acceptLanguage('pt', countryCode: 'PT'), 'pt-BR');
    expect(acceptLanguage('ja', countryCode: 'JP'), 'ja');
  });

  test('formatBytes', () {
    expect(formatBytes(0), '');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(55 * 1024 * 1024), '55.0 MB');
    expect(formatBytes(300 * 1024 * 1024), '300 MB');
  });
}
