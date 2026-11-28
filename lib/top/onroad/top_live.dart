// live view on a TOP device: asks /api/init (port 5001, no pairing) whether to draw TOP's HUD,
// with the device's display settings, and adds the TOP messages to the stream request

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:opview/selfdrive/ui/ui_state.dart';

/// the TOP messages the HUD draws from: asked from TOP devices only, dragonpilot's webrtcd has none of them
const topBridgeServices = ['longitudinalPlanTOP', 'liveMapDataTOP', 'topControlsState', 'carControl'];

/// added to the next /stream request (webrtcd_api.dart)
List<String> extraBridgeServices = const [];

const _initTimeout = Duration(seconds: 2);
const _refreshInterval = Duration(seconds: 10);

/// [hud]: the device's top.hud, null for a device that isn't TOP (stock HUD)
void applyTopHud(UIState state, Map<String, dynamic>? hud) {
  final top = state.top;
  top.isTop = hud != null;
  if (hud == null) return;
  final metric = hud['is_metric'];
  if (metric is bool) state.isMetric = metric;
  top.isMetric = state.isMetric;
  top.speedLimitMode = (hud['speed_limit_mode'] as num?)?.toInt() ?? top.speedLimitMode;
  top.timSignals = hud['tim_signals'] as bool? ?? top.timSignals;
  top.personalityWheel = hud['personality_wheel'] as bool? ?? top.personalityWheel;
}

class TopLive {
  final UIState uiState;
  final http.Client _client;
  Timer? _timer;

  TopLive(this.uiState, {http.Client? client}) : _client = client ?? http.Client();

  /// before connecting: TOP or not, which messages to ask for
  Future<void> check(String host) async {
    final hud = await fetchHud(host);
    applyTopHud(uiState, hud);
    extraBridgeServices = hud != null ? topBridgeServices : const [];
  }

  /// while connected: display settings changed on the device show up within a few seconds
  void start(String host) {
    stop();
    if (!uiState.top.isTop) return;
    _timer = Timer.periodic(_refreshInterval, (_) async {
      final hud = await fetchHud(host);
      if (hud != null) applyTopHud(uiState, hud);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// top.hud of a TOP device ({} from TOP versions before it), null otherwise
  Future<Map<String, dynamic>?> fetchHud(String host) async {
    try {
      final r = await _client.get(Uri(scheme: 'http', host: host, port: 5001, path: '/api/init')).timeout(_initTimeout);
      if (r.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(r.bodyBytes));
      final top = data is Map ? data['top'] : null;
      if (top is! Map) return null;
      final hud = top['hud'];
      return hud is Map ? hud.cast<String, dynamic>() : <String, dynamic>{};
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    stop();
    _client.close();
  }
}
