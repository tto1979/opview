// drives & settings for the device (TOP's opview API, or dragonpilot's dashy)
// landscape: navigation rail on the left, drives / settings on the right

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/ui/routes_view.dart';
import 'package:opview/top/ui/settings_view.dart';

enum _Phase { needHost, connecting, failed, ready }

class DevicePage extends StatefulWidget {
  final String? host;
  final String language;
  final ValueChanged<String>? onHostChanged;

  const DevicePage({super.key, this.host, required this.language, this.onHostChanged});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final _ipController = TextEditingController();
  DeviceApi? _api;
  _Phase _phase = _Phase.needHost;
  String _error = '';
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _ipController.text = host ?? '';
    if (host != null && host.isNotEmpty) _connect(host);
  }

  @override
  void dispose() {
    _api?.close();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _connect(String host) async {
    _api?.close();
    final api = DeviceApi(host, language: widget.language);
    setState(() {
      _api = api;
      _phase = _Phase.connecting;
      _error = '';
    });
    try {
      await api.connect();
      if (api.needsPairing) {
        api.token = await PairingStore.load(api.deviceKey);
        final paired = api.token != null && await _pairingWorks(api);
        if (!paired && !await _pair(api)) {
          _fail(api, T.pairingTitle);
          return;
        }
      }
      if (!mounted || _api != api) return;
      setState(() => _phase = _Phase.ready);
    } on ApiException catch (e) {
      _fail(api, e.noApi ? T.noApi : (e.status == 0 ? T.networkError : e.message));
    }
  }

  void _fail(DeviceApi api, String error) {
    if (!mounted || _api != api) return;
    setState(() {
      _phase = _Phase.failed;
      _error = error;
    });
  }

  Future<bool> _pairingWorks(DeviceApi api) async {
    try {
      await api.checkPairing();
      return true;
    } on ApiException catch (e) {
      if (e.unpaired) return false;
      rethrow;
    }
  }

  /// ask for the code until it works or the user gives up
  Future<bool> _pair(DeviceApi api) async {
    String? error;
    while (true) {
      if (!mounted) return false;
      final code = await showPairingDialog(context, error: error);
      if (code == null || code.isEmpty) return false;
      api.token = code;
      if (await _pairingWorks(api)) {
        await PairingStore.save(api.deviceKey, code);
        return true;
      }
      error = T.pairingWrong;
    }
  }

  /// the device's code changed (or was reset): forget ours and pair again
  Future<void> _repair() async {
    final api = _api;
    if (api == null) return;
    await PairingStore.clear(api.deviceKey);
    if (mounted) _connect(api.host);
  }

  void _submitHost() {
    final host = _ipController.text.trim();
    if (host.isEmpty) return;
    widget.onHostChanged?.call(host);
    _connect(host);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: switch (_phase) {
          _Phase.ready => _ready(),
          _Phase.connecting => _connecting(),
          _Phase.needHost || _Phase.failed => _hostForm(),
        },
      ),
    );
  }

  Widget _connecting() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(T.connecting),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(T.back)),
          ],
        ),
      );

  Widget _hostForm() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _phase == _Phase.failed ? _error : T.noDevice,
                style: TextStyle(color: _phase == _Phase.failed ? Theme.of(context).colorScheme.error : null),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ipController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-zA-Z.:\-]'))],
                decoration: InputDecoration(labelText: T.deviceIp, hintText: '192.168.43.1', border: const OutlineInputBorder()),
                onSubmitted: (_) => _submitHost(),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(T.back)),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _submitHost, child: Text(_phase == _Phase.failed ? T.retry : T.connect)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ready() {
    final api = _api!;
    final offroad = api.info?.isOffroad ?? true;
    return Row(
      children: [
        NavigationRail(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelType: NavigationRailLabelType.all,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: T.back,
            onPressed: () => Navigator.pop(context),
          ),
          trailing: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              children: [
                Icon(offroad ? Icons.local_parking : Icons.directions_car, size: 18),
                Text(offroad ? T.parked : T.driving, style: Theme.of(context).textTheme.labelSmall),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    if (action == 'pair') {
                      _repair();
                    } else {
                      setState(() => _phase = _Phase.needHost);
                    }
                  },
                  itemBuilder: (context) => [
                    if (api.needsPairing) PopupMenuItem(value: 'pair', child: Text(T.pairAgain)),
                    PopupMenuItem(value: 'host', child: Text('${T.changeIp} (${api.host})')),
                  ],
                ),
              ],
            ),
          ),
          destinations: [
            NavigationRailDestination(
              icon: const Icon(Icons.video_library_outlined),
              selectedIcon: const Icon(Icons.video_library),
              label: Text(T.drives),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.tune_outlined),
              selectedIcon: const Icon(Icons.tune),
              label: Text(T.settings),
            ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              RoutesView(api: api, onUnpaired: _repair),
              SettingsView(api: api, onUnpaired: _repair),
            ],
          ),
        ),
      ],
    );
  }
}

Future<String?> showPairingDialog(BuildContext context, {String? error}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(T.pairingTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(T.pairingHint),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, letterSpacing: 8),
            decoration: InputDecoration(errorText: error, border: const OutlineInputBorder(), counterText: ''),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(T.ok)),
      ],
    ),
  );
}
