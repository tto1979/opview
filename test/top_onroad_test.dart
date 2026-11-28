import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/onroad/top_hud.dart';
import 'package:opview/top/onroad/top_live.dart';
import 'package:opview/top/onroad/top_state.dart';

Map<String, dynamic> _plan({
  double limit = 50 / 3.6,
  double offset = 0,
  bool valid = true,
  String source = 'map',
  String assist = 'inactive',
  bool assistActive = false,
  bool vision = false,
  bool visionActive = false,
}) =>
    {
      'speedLimit': {
        'resolver': {
          'speedLimit': limit,
          'speedLimitLast': limit,
          'speedLimitOffset': offset,
          'speedLimitFinalLast': limit + offset,
          'speedLimitValid': valid,
          'speedLimitLastValid': valid,
          'source': source,
        },
        'assist': {'state': assist, 'active': assistActive},
      },
      'smartCruiseControl': {
        'vision': {'enabled': vision, 'active': visionActive},
        'map': {'enabled': false, 'active': false},
      },
    };

Finder _asset(String name) =>
    find.byWidgetPredicate((w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == 'assets/top/$name');

void main() {
  setUp(() => T.zh = false);

  group('TopState', () {
    test('roundHalfEven', () {
      expect(roundHalfEven(2.5), 2);
      expect(roundHalfEven(3.5), 4);
      expect(roundHalfEven(2.49), 2);
      expect(roundHalfEven(49.99999), 50);
      expect(roundHalfEven(-0.5), 0);
    });

    test('speed limit and offset', () {
      final s = TopState()..isMetric = true;
      s.applyLongitudinalPlanTOP(_plan(offset: 5 / 3.6));
      expect(s.speedLimitText, '50');
      expect(s.speedLimitOffsetText, '5');
      s.applyLongitudinalPlanTOP(_plan(offset: -5 / 3.6));
      expect(s.speedLimitOffsetText, '-5');
      expect(s.overspeed(46), isTrue); // limit + offset = 45
      expect(s.overspeed(44), isFalse);
      s.applyLongitudinalPlanTOP(_plan(valid: false));
      expect(s.speedLimitText, '---');
      expect(s.speedLimitOffsetText, '');
      expect(s.overspeed(200), isFalse);
    });

    test('mph', () {
      final s = TopState()..isMetric = false;
      s.applyLongitudinalPlanTOP(_plan(limit: 50 / 2.23694));
      expect(s.speedLimitText, '50');
    });

    test('upcoming limit only while getting closer, from the map', () {
      final s = TopState()..isMetric = true;
      s.applyLongitudinalPlanTOP(_plan());
      final ahead = {'speedLimitAheadValid': true, 'speedLimitAhead': 70 / 3.6, 'roadName': 'Main St'};
      s.applyLiveMapDataTOP({...ahead, 'speedLimitAheadDistance': 500.0});
      expect(s.showSpeedLimitAhead, isFalse);
      s.applyLiveMapDataTOP({...ahead, 'speedLimitAheadDistance': 400.0});
      expect(s.showSpeedLimitAhead, isTrue);
      expect(s.speedLimitAheadDisplay, 70);
      expect(s.aheadDistanceText, '400m');
      expect(s.roadName, 'Main St');
      s.applyLongitudinalPlanTOP(_plan(source: 'car'));
      expect(s.showSpeedLimitAhead, isFalse);
    });

    test('distance texts', () {
      final s = TopState()..isMetric = true;
      String at(double d) {
        s.applyLiveMapDataTOP({'speedLimitAheadDistance': d});
        return s.aheadDistanceText;
      }

      expect(at(30), 'Near');
      expect(at(123), '120m');
      expect(at(1500), '1.5km');
      s.isMetric = false;
      expect(at(10), 'Near');
      expect(at(100), '350ft');
      expect(at(2000), '1.2mi');
      T.zh = true;
      expect(at(2000), '1.2英里');
    });

    test('personality, car state, controls', () {
      final s = TopState();
      s.applySelfdriveState({'personality': 'relaxed'});
      expect(s.personality, 2);
      expect(s.personalityChangedAt, greaterThanOrEqualTo(0));
      s.applySelfdriveState({'personality': 'unknown'});
      expect(s.personality, 1);
      s.applyCarState({'brakeLights': true, 'leftBlinker': true, 'rightBlindspot': true});
      expect([s.brakeLights, s.leftBlinker, s.rightBlinker, s.leftBlindspot, s.rightBlindspot], [true, true, false, false, true]);
      s.applyCarControl({'cruiseControl': {'override': true}});
      expect(s.longOverride, isTrue);
      s.applyTopControlsState({'alkaActive': true});
      expect(s.alkaActive, isTrue);
    });

    test('pulse timing starts with the state', () {
      final s = TopState();
      s.applyLongitudinalPlanTOP(_plan(vision: true, visionActive: true, assist: 'preActive'));
      expect(s.sccVisionSince, isNotNull);
      expect(s.preActiveSince, isNotNull);
      expect(topPulse(s.sccVisionSince), isFalse); // off for the first 40% of each second
      s.applyLongitudinalPlanTOP(_plan());
      expect(s.sccVisionSince, isNull);
      expect(s.preActiveSince, isNull);
    });

    test('side indicator', () {
      final i = SideIndicator();
      i.update(false, true, 0);
      expect(i.show, isTrue);
      expect(i.blindSpotColor, isTrue);
      i.update(false, false, 1.0);
      expect(i.show, isFalse);
      i.update(true, false, 1.1);
      expect(i.show, isFalse);
      i.update(true, false, 1.5);
      expect(i.show, isTrue);
      expect(i.blindSpotColor, isFalse);
      i.update(true, true, 1.65); // towards a car in the blind spot: fast, yellow
      expect(i.blindSpotColor, isTrue);
      expect(i.show, isTrue);
    });
  });

  group('device settings', () {
    test('applyTopHud', () {
      final s = UIState();
      applyTopHud(s, null);
      expect(s.top.isTop, isFalse);
      applyTopHud(s, {'is_metric': false, 'speed_limit_mode': 2, 'tim_signals': false, 'personality_wheel': false});
      expect(s.top.isTop, isTrue);
      expect(s.isMetric, isFalse);
      expect(s.top.isMetric, isFalse);
      expect(s.top.speedLimitMode, 2);
      expect(s.top.timSignals, isFalse);
      expect(s.top.personalityWheel, isFalse);
      applyTopHud(s, {}); // TOP before the hud settings: keeps what it had
      expect(s.top.isTop, isTrue);
      expect(s.top.speedLimitMode, 2);
      s.dispose();
    });

    test('TopLive asks TOP devices for the TOP messages only', () async {
      final s = UIState();
      http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

      var live = TopLive(s, client: MockClient((req) async {
        expect(req.url.toString(), 'http://10.0.0.2:5001/api/init');
        return json({'isOffroad': false, 'top': {'api': 1, 'hud': {'speed_limit_mode': 3}}});
      }));
      await live.check('10.0.0.2');
      expect(s.top.isTop, isTrue);
      expect(s.top.speedLimitMode, 3);
      expect(extraBridgeServices, topBridgeServices);

      live = TopLive(s, client: MockClient((req) async => http.Response('Not Found', 404)));
      await live.check('10.0.0.2');
      expect(s.top.isTop, isFalse);
      expect(extraBridgeServices, isEmpty);

      live = TopLive(s, client: MockClient((req) async => json({'dp_dev_dashy': 1, 'isOffroad': true})));
      expect(await live.fetchHud('10.0.0.2'), isNull);
      live = TopLive(s, client: MockClient((req) async => json({'isOffroad': true, 'top': {'api': 1}})));
      expect(await live.fetchHud('10.0.0.2'), <String, dynamic>{});
      live = TopLive(s, client: MockClient((req) async => throw http.ClientException('refused')));
      expect(await live.fetchHud('10.0.0.2'), isNull);
      s.dispose();
    });
  });

  group('drawing', () {
    UIState driving({required bool metric}) {
      final s = UIState();
      applyTopHud(s, {'is_metric': metric, 'speed_limit_mode': 2, 'tim_signals': true, 'personality_wheel': true});
      s.applyCarState({'vEgo': 20.0, 'vCruiseCluster': 60.0});
      s.top.applyCarState({'leftBlinker': true, 'leftBlindspot': true, 'rightBlinker': true, 'brakeLights': true});
      s.top.applyLongitudinalPlanTOP(_plan(limit: metric ? 50 / 3.6 : 50 / 2.23694, offset: metric ? 5 / 3.6 : 5 / 2.23694, vision: true));
      final ahead = {'roadName': '中山北路', 'speedLimitAheadValid': true, 'speedLimitAhead': 70 / 3.6};
      s.top.applyLiveMapDataTOP({...ahead, 'speedLimitAheadDistance': 400.0});
      s.top.applyLiveMapDataTOP({...ahead, 'speedLimitAheadDistance': 300.0});
      s.top.applySelfdriveState({'personality': 'aggressive'});
      s.top.applyTopControlsState({'alkaActive': true});
      return s;
    }

    Future<void> pump(WidgetTester tester, UIState s) async {
      await tester.binding.setSurfaceSize(const Size(2160, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SizedBox(width: 2100, height: 1020, child: TopHudLayer(uiState: s, scale: 1.0))),
      ));
      await tester.pump();
    }

    testWidgets('metric: round sign, upcoming limit, badges, road name, personality', (tester) async {
      final s = driving(metric: true);
      await pump(tester, s);
      expect(tester.takeException(), isNull);
      expect(find.text('50'), findsOneWidget);
      // centered in the sign's white circle (the layer is at 30, 30): sized to the text, not the circle
      final center = tester.getCenter(find.text('50'));
      expect(center.dx, closeTo(30 + 280 + 100, 2));
      expect(center.dy, closeTo(30 + 45 + 102, 2));
      // the test font's glyphs are squares (width = size per glyph): check the height, which used to be the box's
      expect(tester.getSize(find.text('50')).height, lessThan(152));
      expect(tester.getSize(find.text('V-TSC')).height, lessThan(52));
      expect(find.text('5'), findsOneWidget);
      expect(find.text('AHEAD'), findsOneWidget);
      expect(find.text('V-TSC'), findsOneWidget);
      expect(find.text('中山北路'), findsOneWidget);
      expect(find.text('Aggressive'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(3)); // both blinkers, the logo
      expect(_asset('button_home.png'), findsOneWidget);
      s.applySelfdriveState({'experimentalMode': true, 'enabled': true});
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SizedBox(width: 2100, height: 1020, child: TopHudLayer(uiState: s, scale: 1.0))),
      ));
      expect(_asset('experimental.png'), findsOneWidget);
      s.dispose();
    });

    testWidgets('current speed where the device draws it, under the road name', (tester) async {
      final s = driving(metric: true);
      await tester.binding.setSurfaceSize(const Size(2160, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SizedBox(width: 2100, height: 1020, child: Stack(children: [HudRenderer(uiState: s, scale: 1.0)]))),
      ));
      expect(tester.getCenter(find.text('72')).dy, closeTo(30 + 150, 2)); // 20 m/s
      expect(tester.getCenter(find.text('km/h')).dy, closeTo(30 + 260, 2));
      expect(tester.getTopLeft(find.text('72')).dy, greaterThan(30 + 56)); // the road name box ends at 56
      s.dispose();
    });

    testWidgets('imperial: US sign', (tester) async {
      final s = driving(metric: false);
      await pump(tester, s);
      expect(tester.takeException(), isNull);
      expect(find.text('SPEED'), findsOneWidget);
      expect(find.text('LIMIT'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
      s.dispose();
    });

    test('colors and border', () {
      final s = driving(metric: true);
      expect(topHeaderGradientStart(s), TopColors.brakeGradientStart);
      expect(topSetSpeedColors(s)!.max, TopColors.white); // cruise set, disengaged
      s.top.applyLongitudinalPlanTOP(_plan(assistActive: true));
      expect(topSetSpeedColors(s)!.speed, TopColors.green);
      expect(topBorder(s)!.color, TopColors.alkaBorder);
      applyTopHud(s, null);
      expect(topHeaderGradientStart(s), isNull);
      expect(topSetSpeedColors(s), isNull);
      expect(topBorder(s), isNull);
      s.dispose();
    });
  });
}
