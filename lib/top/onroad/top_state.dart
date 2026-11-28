// TOP onroad state: speed limit, smart cruise control, blinkers / blind spot, brake lights,
// driving personality and ALKA, from the TOP messages the live view asks TOP devices for
// port of TOP's selfdrive/ui/onroad/top_state.py (+ the border indicators of augmented_road_view.py)

import 'package:opview/top/l10n.dart';

const _msToKph = 3.6;
const _msToMph = 2.23694;
const _meterToFoot = 3.28084;
const _meterToMile = 0.000621371;
const _speedLimitAheadValidFrameThreshold = 5;

/// speed limit modes (SpeedLimitMode param)
const speedLimitModeOff = 0;
const speedLimitModeWarning = 2;

final _clock = Stopwatch()..start();

/// monotonic seconds, for the blinking and the animations
double topNow() => _clock.elapsedMicroseconds / 1e6;

/// std::nearbyint / python's round(): halves to even, so 49.5 doesn't flicker between 49 and 50
int roundHalfEven(double v) {
  final f = v.floorToDouble();
  final diff = v - f;
  final fi = f.toInt();
  if (diff > 0.5) return fi + 1;
  if (diff < 0.5) return fi;
  return fi.isEven ? fi : fi + 1;
}

/// blink at 1 Hz, on 60% of the time (top_state.py _pulse)
bool topPulse(double? since) => since != null && (topNow() - since) % 1.0 >= 0.4;

/// blinker / blind spot indicator on one side of the border (from dragonpilot)
class SideIndicator {
  static const blinkStd = 0.4; // s
  static const blinkFast = 0.2; // s, blinker towards a car in the blind spot

  bool show = false;
  bool blindSpotColor = false; // yellow, else green
  double _start = 0;

  void update(bool blinker, bool blindSpot, [double? now]) {
    final t = now ?? topNow();
    if (!blinker && !blindSpot) {
      show = false;
      _start = t;
      return;
    }
    if (blinker) {
      blindSpotColor = blindSpot;
      final period = blindSpot ? blinkFast : blinkStd;
      show = ((t - _start) / period).floor() % 2 == 1;
    } else {
      blindSpotColor = true;
      show = true;
    }
  }
}

double _d(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
bool _b(dynamic v) => v == true;
Map<String, dynamic> _m(dynamic v) => v is Map ? v.cast<String, dynamic>() : const {};

class TopState {
  /// a TOP device (its /api/init said so): draw TOP's HUD
  bool isTop = false;

  // the device's display settings (/api/init top.hud)
  bool isMetric = true;
  int speedLimitMode = 1;
  bool timSignals = true;
  bool personalityWheel = true;

  // carState
  bool brakeLights = false;
  bool leftBlinker = false;
  bool rightBlinker = false;
  bool leftBlindspot = false;
  bool rightBlindspot = false;

  // selfdriveState
  int personality = 1; // aggressive, standard, relaxed
  int? _lastPersonality;
  double personalityChangedAt = -100;

  // carControl
  bool longOverride = false;

  // topControlsState
  bool alkaActive = false;

  // longitudinalPlanTOP, speeds in m/s
  double speedLimit = 0;
  double speedLimitLast = 0;
  double speedLimitOffset = 0;
  double speedLimitFinalLast = 0;
  bool speedLimitValid = false;
  bool speedLimitLastValid = false;
  String speedLimitSource = 'none'; // none, car, map
  String assistState = 'disabled'; // disabled, inactive, preActive, pending, adapting, active
  bool assistActive = false;
  double? preActiveSince;
  bool sccVisionEnabled = false;
  bool sccVisionActive = false;
  double? sccVisionSince;
  bool sccMapEnabled = false;
  bool sccMapActive = false;
  double? sccMapSince;

  // liveMapDataTOP
  String roadName = '';
  bool speedLimitAheadValid = false;
  double speedLimitAhead = 0; // m/s
  double speedLimitAheadDistance = 0; // m
  double _aheadDistancePrev = 0;
  int _aheadValidFrame = 0;

  // border indicators
  final leftIndicator = SideIndicator();
  final rightIndicator = SideIndicator();

  // -- apply, one per message --

  void applyCarState(Map<String, dynamic> data) {
    brakeLights = _b(data['brakeLights']);
    leftBlinker = _b(data['leftBlinker']);
    rightBlinker = _b(data['rightBlinker']);
    leftBlindspot = _b(data['leftBlindspot']);
    rightBlindspot = _b(data['rightBlindspot']);
  }

  void applySelfdriveState(Map<String, dynamic> data) {
    const names = {'aggressive': 0, 'standard': 1, 'relaxed': 2};
    final p = data['personality'];
    personality = (p is num ? p.toInt() : names[p]) ?? 1;
    if (personality < 0 || personality > 2) personality = 1;
    // the name shows for a few seconds after a change, and when going onroad
    if (_lastPersonality != personality) {
      _lastPersonality = personality;
      personalityChangedAt = topNow();
    }
  }

  void applyCarControl(Map<String, dynamic> data) {
    longOverride = _b(_m(data['cruiseControl'])['override']);
  }

  void applyTopControlsState(Map<String, dynamic> data) {
    alkaActive = _b(data['alkaActive']);
  }

  void applyLongitudinalPlanTOP(Map<String, dynamic> data) {
    final limit = _m(data['speedLimit']);
    final resolver = _m(limit['resolver']);
    final assist = _m(limit['assist']);
    speedLimit = _d(resolver['speedLimit']);
    speedLimitLast = _d(resolver['speedLimitLast']);
    speedLimitOffset = _d(resolver['speedLimitOffset']);
    speedLimitFinalLast = _d(resolver['speedLimitFinalLast']);
    speedLimitValid = _b(resolver['speedLimitValid']);
    speedLimitLastValid = _b(resolver['speedLimitLastValid']);
    speedLimitSource = '${resolver['source'] ?? 'none'}';
    assistState = '${assist['state'] ?? 'disabled'}';
    assistActive = _b(assist['active']);
    preActiveSince = assistState == 'preActive' ? (preActiveSince ?? topNow()) : null;

    final scc = _m(data['smartCruiseControl']);
    final vision = _m(scc['vision']);
    final map = _m(scc['map']);
    sccVisionEnabled = _b(vision['enabled']);
    sccVisionActive = _b(vision['active']);
    sccVisionSince = sccVisionActive ? (sccVisionSince ?? topNow()) : null;
    sccMapEnabled = _b(map['enabled']);
    sccMapActive = _b(map['active']);
    sccMapSince = sccMapActive ? (sccMapSince ?? topNow()) : null;
  }

  void applyLiveMapDataTOP(Map<String, dynamic> data) {
    roadName = '${data['roadName'] ?? ''}';
    speedLimitAheadValid = _b(data['speedLimitAheadValid']);
    speedLimitAhead = _d(data['speedLimitAhead']);
    speedLimitAheadDistance = _d(data['speedLimitAheadDistance']);
    // only show the upcoming limit while getting closer to it
    if (speedLimitAheadDistance < _aheadDistancePrev && _aheadValidFrame < _speedLimitAheadValidFrameThreshold) {
      _aheadValidFrame++;
    } else if (speedLimitAheadDistance > _aheadDistancePrev && _aheadValidFrame > 0) {
      _aheadValidFrame--;
    }
    _aheadDistancePrev = speedLimitAheadDistance;
  }

  // -- for drawing (speeds in km/h or mph) --

  double get _conv => isMetric ? _msToKph : _msToMph;

  bool get hasSpeedLimit => speedLimitValid || speedLimitLastValid;

  /// over the limit (+ offset) at [speed] (km/h or mph)
  bool overspeed(double speed) => hasSpeedLimit && roundHalfEven(speedLimitFinalLast * _conv) < roundHalfEven(speed);

  String get speedLimitText => hasSpeedLimit ? '${roundHalfEven(speedLimitLast * _conv)}' : '---';

  /// the offset bubble, '' without one
  String get speedLimitOffsetText {
    final offset = roundHalfEven(speedLimitOffset * _conv);
    if (offset == 0 || !hasSpeedLimit) return '';
    return '${speedLimitOffset > 0 ? '' : '-'}${offset.abs()}';
  }

  /// showing the last known limit, the current one isn't valid
  bool get speedLimitStale => !speedLimitValid && speedLimitLastValid;

  int get speedLimitFinalLastDisplay => roundHalfEven(speedLimitFinalLast * _conv);

  int get speedLimitAheadDisplay => roundHalfEven(speedLimitAhead * _conv);

  bool get showSpeedLimitAhead =>
      speedLimitAheadValid &&
      speedLimitAhead > 0 &&
      speedLimitAhead * _conv != speedLimit * _conv &&
      _aheadValidFrame > 0 &&
      speedLimitSource == 'map';

  String get aheadDistanceText {
    final d = speedLimitAheadDistance;
    int roundTo(double distance, int interval, int threshold) {
      final base = (distance / interval).floor() * interval;
      return distance - base >= threshold ? base + interval : base;
    }

    if (isMetric) {
      if (d < 50) return T.near;
      if (d >= 1000) return '${(d / 1000).toStringAsFixed(1)}${T.km}';
      final rounded = d < 200 ? (roundTo(d, 10, 5) < 10 ? 10 : roundTo(d, 10, 5)) : roundTo(d, 100, 50);
      return '$rounded${T.meter}';
    }
    final ft = d * _meterToFoot;
    if (ft < 100) return T.near;
    if (ft >= 900) return '${(d * _meterToMile).toStringAsFixed(1)}${T.mile}';
    final rounded = ft < 500 ? (roundTo(ft, 50, 25) < 50 ? 50 : roundTo(ft, 50, 25)) : roundTo(ft, 100, 50);
    return '$rounded${T.foot}';
  }
}
