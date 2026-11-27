// opview app shell
// dark theme; the onroad view, plus drives & settings (TOP) behind a button:
// always shown while not connected, a tap away while driving

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/ui/device_page.dart';

const _menuButtonTime = Duration(seconds: 4);

class OpviewApp extends StatefulWidget {
  const OpviewApp({super.key});

  @override
  State<OpviewApp> createState() => _OpviewAppState();
}

class _OpviewAppState extends State<OpviewApp> with WidgetsBindingObserver {
  late final UIState _uiState;
  late final ConnectionManager _connectionManager;
  bool _menuVisible = false;
  bool _inDevicePage = false;
  Timer? _menuTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
    _connectionManager = ConnectionManager(_uiState);
    _connectionManager.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _menuTimer?.cancel();
    // async cleanup — best-effort, State.dispose() is sync
    _connectionManager.dispose();
    _uiState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // the live view stays off while drives & settings are open
      if (_inDevicePage) return;
      debugPrint('[opview] app resumed, reconnecting');
      _connectionManager.reconnect();
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[opview] app paused, stopping');
      _connectionManager.pause();
    }
  }

  void _showMenuButton() {
    _menuTimer?.cancel();
    setState(() => _menuVisible = true);
    _menuTimer = Timer(_menuButtonTime, () {
      if (mounted) setState(() => _menuVisible = false);
    });
  }

  /// drives & settings: the live view is paused meanwhile (bandwidth for videos and downloads)
  Future<void> _openDevicePage(BuildContext context) async {
    _menuTimer?.cancel();
    setState(() => _menuVisible = false);
    _inDevicePage = true;
    _connectionManager.pause();
    final locale = PlatformDispatcher.instance.locale;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DevicePage(
        host: _connectionManager.knownHost,
        language: acceptLanguage(locale.languageCode, scriptCode: locale.scriptCode, countryCode: locale.countryCode),
        onHostChanged: _connectionManager.setManualHost,
      ),
    ));
    _inDevicePage = false;
    if (mounted) _connectionManager.reconnect();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'topview',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              ListenableBuilder(
                listenable: _uiState,
                builder: (context, _) => AugmentedRoadView(
                  uiState: _uiState,
                  videoRenderer: _connectionManager.videoRenderer,
                ),
              ),
              // a tap anywhere brings up the drives & settings button for a few seconds
              Positioned.fill(
                child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _showMenuButton),
              ),
              ListenableBuilder(
                listenable: _uiState,
                builder: (context, _) {
                  final visible = _menuVisible || !_uiState.isConnected;
                  return Positioned(
                    top: 16,
                    right: 16,
                    child: SafeArea(
                      child: IgnorePointer(
                        ignoring: !visible,
                        child: AnimatedOpacity(
                          opacity: visible ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: FilledButton.tonalIcon(
                            onPressed: () => _openDevicePage(context),
                            icon: const Icon(Icons.video_library_outlined),
                            label: Text(T.menu),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
