// TOP's additions to the onroad HUD, drawn over the camera like on the device
// port of TOP's selfdrive/ui/onroad/top_hud.py (comma 3/3X layout) and the border parts of its
// augmented_road_view.py: 1080 px tall reference, scaled to the screen like the rest of the HUD
//
// - road name, brake light tint on the header
// - speed limit sign (round in metric, US style in imperial) with offset bubble, the upcoming limit
//   and the speed limit assist +/- arrows; set speed colors for speed limit assist
// - Smart Cruise Control V-TSC / M-TSC badges
// - driving personality icon, turn signal / blind spot animation
// - the TOP logo in the experimental mode button's place (the experimental icon in experimental mode)
// - ALKA border color, blinker / blind spot on the sides of the border

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/onroad/top_state.dart';

const _signY = 45.0;
const _signHeight = 204.0;
const _turnSignalSize = 142.0;
const _turnSignalFrameTime = 0.4; // s per animation frame
const _personalityTextDuration = 3.0;
const _personalityFadeDuration = 1.0;
const _indicatorWidth = 0.2; // share of the screen width

class TopColors {
  static const green = Color(0xFF00FF00);
  static const overrideGrey = Color(0xF1919B95);
  static const red = Color(0xFFFF0000);
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const offsetBorder = Color(0xFF4D4D4D);
  static const roadName = Color(0xFFFFD700);
  static const brakeGradientStart = Color(0x72FF7A80);
  static const alkaBorder = Color(0xF16FC0C9);
  static const indicatorBlinker = Color(0xFF00FF00);
  static const indicatorBlindSpot = Color(0xFFFFFF00);
  // hud_renderer.py's, for TOP's set speed
  static const engaged = Color(0xFF80D8A6);
  static const override_ = Color(0xFF919B95);
  static const grey = Color(0xFFA6A6A6);
  static const darkGrey = Color(0xFF727272);
}

/// header gradient start color: red tint while braking, null for the stock one
Color? topHeaderGradientStart(UIState s) => s.top.isTop && s.top.brakeLights ? TopColors.brakeGradientStart : null;

/// TOP's MAX label and set speed colors (green with speed limit assist, grey on gas override), null for stock
({Color max, Color speed})? topSetSpeedColors(UIState s) {
  if (!s.top.isTop) return null;
  final top = s.top;
  var maxColor = TopColors.grey;
  var speedColor = TopColors.darkGrey;
  if (s.isCruiseSet) {
    speedColor = TopColors.white;
    if (top.assistActive) {
      speedColor = top.longOverride ? TopColors.overrideGrey : TopColors.green;
      maxColor = top.longOverride ? TopColors.overrideGrey : TopColors.engaged;
    } else if (s.status == UIStatus.disengaged) {
      maxColor = TopColors.white;
    } else if (s.status == UIStatus.override_) {
      maxColor = TopColors.override_;
    } else {
      maxColor = TopColors.engaged;
    }
  }
  return (max: maxColor, speed: speedColor);
}

/// border additions: ALKA color, blinker / blind spot on the left and right fifth of the border
class TopBorder {
  final Color? color;
  final Color? left;
  final Color? right;

  const TopBorder({this.color, this.left, this.right});

  static const width = _indicatorWidth;
}

TopBorder? topBorder(UIState s) {
  if (!s.top.isTop) return null;
  final top = s.top;
  final now = topNow();
  top.leftIndicator.update(top.leftBlinker, top.leftBlindspot, now);
  top.rightIndicator.update(top.rightBlinker, top.rightBlindspot, now);
  Color? side(SideIndicator i) =>
      i.show ? (i.blindSpotColor ? TopColors.indicatorBlindSpot : TopColors.indicatorBlinker) : null;
  return TopBorder(
    color: top.alkaActive && s.status == UIStatus.disengaged ? TopColors.alkaBorder : null,
    left: side(top.leftIndicator),
    right: side(top.rightIndicator),
  );
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

class TopHudLayer extends StatelessWidget {
  final UIState uiState;
  final double scale;

  const TopHudLayer({super.key, required this.uiState, required this.scale});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // content size in reference pixels (the HUD area inside the border)
      final w = constraints.maxWidth / scale;
      final h = constraints.maxHeight / scale;
      final top = uiState.top;
      final out = <Widget>[];
      _roadName(out);
      if (uiState.isCruiseAvailable) {
        _sccBadges(out, w, h);
        _speedLimit(out);
      }
      _expButton(out, w);
      if (top.personalityWheel && uiState.alertSize == 0) _personality(out, w, h);
      if (top.timSignals && (top.leftBlinker || top.rightBlinker)) _turnSignals(out, w, h);
      return Stack(children: out);
    });
  }

  // -- helpers --

  Rect _r(double x, double y, double w, double h) => Rect.fromLTWH(x * scale, y * scale, w * scale, h * scale);

  TextStyle _style(double size, Color color, FontWeight weight) =>
      TextStyle(fontSize: size * scale, color: color, fontWeight: weight, height: 1.0);

  /// text centered on x with its top at y (raylib draws text from its top left corner)
  Widget _textAt(String text, double cx, double y, double size, Color color, FontWeight weight) => Positioned(
        left: (cx - 300) * scale,
        width: 600 * scale,
        top: y * scale,
        child: Text(text, textAlign: TextAlign.center, maxLines: 1, softWrap: false, style: _style(size, color, weight)),
      );

  /// text centered in a box (scaled rect), may be wider than it
  Widget _textIn(Rect box, String text, double size, Color color, FontWeight weight) => Positioned.fromRect(
        rect: box,
        // min 0: OverflowBox passes the box's tight size on as the minimum otherwise, the text then fills the
        // whole box and sits in its top left corner
        child: OverflowBox(
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Text(text, maxLines: 1, softWrap: false, textAlign: TextAlign.center, style: _style(size, color, weight)),
        ),
      );

  Widget _box(Rect r, {Color? color, double radius = 0, Color? border, double borderWidth = 0}) => Positioned.fromRect(
        rect: r,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius * scale),
            border: border == null ? null : Border.all(color: border, width: borderWidth * scale),
          ),
        ),
      );

  Widget _circle(double cx, double cy, double radius, Color color) => Positioned.fromRect(
        rect: _r(cx - radius, cy - radius, radius * 2, radius * 2),
        child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      );

  Widget _image(Rect r, String name, {bool flip = false, double opacity = 1}) {
    Widget image = Image.asset('assets/top/$name', fit: BoxFit.fill, gaplessPlayback: true);
    if (flip) image = Transform.flip(flipX: true, child: image);
    if (opacity < 1) image = Opacity(opacity: opacity, child: image);
    return Positioned.fromRect(rect: r, child: image);
  }

  // -- road name --

  void _roadName(List<Widget> out) {
    final name = uiState.top.roadName;
    if (name.isEmpty) return;
    out.add(Positioned(
      top: -4 * scale,
      left: 20 * scale,
      right: 20 * scale,
      height: 60 * scale,
      child: Center(
        child: Container(
          constraints: BoxConstraints(minWidth: 200 * scale),
          padding: EdgeInsets.symmetric(horizontal: 20 * scale),
          decoration: BoxDecoration(color: const Color(0x78000000), borderRadius: BorderRadius.circular(12 * scale)),
          child: Center(
            widthFactor: 1,
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style(48, TopColors.roadName, FontWeight.w600)),
          ),
        ),
      ),
    ));
  }

  // -- smart cruise control --

  void _sccBadges(List<Widget> out, double w, double h) {
    final top = uiState.top;
    const orders = [-70.0, -150.0];
    var i = 0;
    var yVision = 0.0;
    var yMap = 0.0;
    if (top.sccVisionEnabled) yVision = orders[i++];
    if (top.sccMapEnabled) yMap = orders[i];
    if ((top.sccVisionEnabled && !top.sccVisionActive) || (top.sccVisionActive && topPulse(top.sccVisionSince))) {
      _sccBadge(out, w, h, yVision, 'V-TSC');
    }
    if ((top.sccMapEnabled && !top.sccMapActive) || (top.sccMapActive && topPulse(top.sccMapSince))) {
      _sccBadge(out, w, h, yMap, 'M-TSC');
    }
  }

  void _sccBadge(List<Widget> out, double w, double h, double yOffset, String text) {
    const boxW = 160.0;
    const boxH = 52.0;
    final cx = w / 2 - 260;
    final cy = h / 4 + yOffset;
    final box = _r(cx - boxW / 2, cy - boxH / 2, boxW, boxH);
    out.add(_box(box, color: uiState.top.longOverride ? TopColors.overrideGrey : TopColors.green, radius: 10));
    out.add(_textIn(box, text, 42, const Color(0xC8000000), FontWeight.w700));
  }

  // -- speed limit --

  Rect get _sign {
    final metric = uiState.isMetric;
    return Rect.fromLTWH(metric ? 280 : 272, _signY, metric ? 200 : 172, _signHeight);
  }

  void _speedLimit(List<Widget> out) {
    final top = uiState.top;
    final sign = _sign;
    final preActive = top.assistState == 'preActive';
    bool show;
    if (preActive) {
      show = topPulse(top.preActiveSince);
      _preActiveArrow(out, sign);
    } else {
      show = top.speedLimitMode != speedLimitModeOff;
    }
    if (!show) return;
    if (uiState.isMetric) {
      _roundSign(out, sign);
    } else {
      _usSign(out, sign);
    }
    if (!preActive) _upcomingSpeedLimit(out, sign);
  }

  Color _limitColor() {
    final top = uiState.top;
    if (top.speedLimitMode >= speedLimitModeWarning && top.overspeed(uiState.displaySpeed)) return TopColors.red;
    if (top.speedLimitStale) return TopColors.overrideGrey;
    return TopColors.black;
  }

  double _subFactor(String sub) => sub.length >= 3 ? 0.475 : (uiState.isMetric ? 0.5 : 0.6);

  /// EU Vienna Convention style round sign
  void _roundSign(List<Widget> out, Rect sign) {
    final top = uiState.top;
    final size = min(sign.width, sign.height);
    final cx = sign.left + sign.width / 2;
    final cy = sign.top + sign.height / 2;
    final radius = size / 2;
    final ring = size * 0.12;
    out.add(_circle(cx, cy, radius, TopColors.red));
    out.add(_circle(cx, cy, radius - ring, TopColors.white));
    final text = top.speedLimitText;
    final inner = _r(cx - radius + ring, cy - radius + ring, size - 2 * ring, size - 2 * ring);
    out.add(_textIn(inner, text, text.length >= 3 ? 70 : 85, _limitColor(), FontWeight.w700));

    final sub = top.speedLimitOffsetText;
    if (sub.isEmpty) return;
    final off = size * 0.4;
    final overlap = off * 0.25;
    final ox = cx + radius - off / 1.25 + overlap;
    final oy = cy - radius - off / 1.75 + overlap;
    out.add(_circle(ox + off / 2, oy + off / 2, off / 2 + 3, TopColors.offsetBorder));
    out.add(_circle(ox + off / 2, oy + off / 2, off / 2 - 3, TopColors.black));
    out.add(_textIn(_r(ox, oy, off, off), sub, off * _subFactor(sub), TopColors.white, FontWeight.w700));
  }

  /// US / Canada MUTCD style sign
  void _usSign(List<Widget> out, Rect sign) {
    final top = uiState.top;
    out.add(_box(_r(sign.left, sign.top, sign.width, sign.height), color: TopColors.white, radius: 32));
    final inner = Rect.fromLTWH(sign.left + 10, sign.top + 10, sign.width - 20, sign.height - 20);
    out.add(_box(_r(inner.left, inner.top, inner.width, inner.height), radius: 22, border: TopColors.black, borderWidth: 4));
    final cx = inner.left + inner.width / 2;
    out.add(_textAt(T.speedSign, cx, inner.top + 10, 40, TopColors.black, FontWeight.w600));
    out.add(_textAt(T.limitSign, cx, inner.top + 50, 40, TopColors.black, FontWeight.w600));
    out.add(_textAt(top.speedLimitText, cx, inner.top + 80, 90, _limitColor(), FontWeight.w700));

    final sub = top.speedLimitOffsetText;
    if (sub.isEmpty) return;
    final box = sign.width * 0.4;
    final overlap = box * 0.25;
    final r = _r(sign.left + sign.width - box / 1.5 + overlap, sign.top - box / 1.25 + overlap, box, box);
    out.add(_box(r, color: TopColors.black, radius: box * 0.2, border: TopColors.offsetBorder, borderWidth: 6));
    out.add(_textIn(r, sub, box * _subFactor(sub), TopColors.white, FontWeight.w700));
  }

  void _upcomingSpeedLimit(List<Widget> out, Rect sign) {
    final top = uiState.top;
    if (!top.showSpeedLimitAhead) return;
    const w = 170.0;
    const h = 160.0;
    final x = sign.left + (sign.width - w) / 2;
    final y = sign.top + sign.height + 10;
    out.add(_box(_r(x, y, w, h), color: const Color(0xB4000000), radius: 16, border: const Color(0x64FFFFFF), borderWidth: 3));
    final cx = x + w / 2;
    out.add(_textAt(T.ahead, cx, y + 4, 40, const Color(0xFFC8C8C8), FontWeight.w600));
    out.add(_textAt('${top.speedLimitAheadDisplay}', cx, y + 38, 70, TopColors.white, FontWeight.w700));
    out.add(_textAt(top.aheadDistanceText, cx, y + 110, 40, const Color(0xFFB4B4B4), FontWeight.w400));
  }

  /// speed limit assist waiting for the driver: +/- arrow towards the limit, bouncing
  void _preActiveArrow(List<Widget> out, Rect sign) {
    final top = uiState.top;
    final setSpeed = roundHalfEven(uiState.setSpeed);
    final limit = top.speedLimitFinalLastDisplay;
    if (setSpeed == limit) return;
    final since = top.preActiveSince;
    final t = since == null ? 0.0 : topNow() - since;
    final bounce = 20 * sin(t * 2 * pi);
    final up = setSpeed < limit;
    const size = 105.0;
    final x = sign.left + sign.width + 36;
    final y = sign.top + sign.height / 2 - size / 2 + (up ? bounce : -bounce);
    out.add(_image(_r(x, y, size, size), up ? 'img_plus_arrow_up.png' : 'img_minus_arrow_down.png'));
  }

  // -- experimental mode button: TOP's logo, no dark circle (exp_button.py + TopHudRenderer) --

  void _expButton(List<Widget> out, double w) {
    const buttonSize = 192.0;
    const iconSize = 144.0;
    final cx = w - 30 - buttonSize / 2;
    const cy = 30 + buttonSize / 2;
    final experimental = uiState.experimentalMode;
    final size = experimental ? iconSize : iconSize * 1.4;
    out.add(_image(
      _r(cx - size / 2, cy - size / 2, size, size),
      experimental ? 'experimental.png' : 'button_home.png',
      opacity: uiState.top.engageable ? 1.0 : 180 / 255,
    ));
  }

  // -- personality --

  void _personality(List<Widget> out, double w, double h) {
    final top = uiState.top;
    final elapsed = topNow() - top.personalityChangedAt;
    // same spot as on the device: bottom right
    final x = w - 77 - 60;
    final y = h - 30 - 80;
    final textOpacity = _clamp01(1.0 - (elapsed - _personalityTextDuration) / _personalityFadeDuration);
    final imageOpacity = _clamp01((elapsed - _personalityTextDuration) / _personalityFadeDuration);
    if (elapsed < _personalityTextDuration && textOpacity > 0) {
      out.add(_textIn(_r(x - 300, y - 40, 600, 80), T.personality(top.personality), 40,
          Color.fromRGBO(255, 255, 255, textOpacity), FontWeight.w700));
    }
    if (imageOpacity > 0) {
      const names = ['aggressive.png', 'standard.png', 'relaxed.png'];
      out.add(_image(_r(x - 94, y - 61, 188, 122), names[top.personality], opacity: imageOpacity));
    }
  }

  // -- turn signals --

  void _turnSignals(List<Widget> out, double w, double h) {
    final top = uiState.top;
    final frame = (topNow() / _turnSignalFrameTime).floor() % 2;
    final y = (top.leftBlindspot || top.rightBlindspot) ? (h - _turnSignalSize) / 2 : 350.0;
    final leftX = w / 2 - 50 - 360 * (top.leftBlindspot ? 2 : 0);
    final rightX = w / 2 - 50 + 360 * (top.rightBlindspot ? 2 : 0);
    String name(bool blindSpot) => blindSpot ? 'tim_turn_signal_1_red.png' : 'tim_turn_signal_${frame + 1}.png';
    if (top.leftBlinker) {
      out.add(_image(_r(leftX, y, _turnSignalSize, _turnSignalSize), name(top.leftBlindspot)));
    }
    if (top.rightBlinker) {
      out.add(_image(_r(rightX, y, _turnSignalSize, _turnSignalSize), name(top.rightBlindspot), flip: true));
    }
  }
}
