// drives on the device, newest first

import 'package:flutter/material.dart';
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/ui/route_page.dart';

class RoutesView extends StatefulWidget {
  final DeviceApi api;
  final VoidCallback onUnpaired;

  const RoutesView({super.key, required this.api, required this.onUnpaired});

  @override
  State<RoutesView> createState() => _RoutesViewState();
}

class _RoutesViewState extends State<RoutesView> {
  List<RouteInfo>? _routes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final routes = await widget.api.routes();
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.unpaired) {
        widget.onUnpaired();
        return;
      }
      setState(() => _error = e.status == 0 ? T.networkError : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routes = _routes;
    if (routes == null && _error == null) return const Center(child: CircularProgressIndicator());

    // pull to refresh everywhere, also on the empty / error views
    return RefreshIndicator(
      onRefresh: _load,
      child: routes == null || routes.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(child: Text(_error != null ? T.loadFailed(_error!) : T.noDrives)),
                if (_error != null)
                  Center(child: TextButton(onPressed: _load, child: Text(T.retry))),
              ],
            )
          : ListView.separated(
              itemCount: routes.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _tile(routes[i]),
            ),
    );
  }

  Widget _tile(RouteInfo r) {
    final details = [
      T.minutes((r.duration / 60).round()),
      T.segments(r.segments.length),
      formatBytes(r.size),
    ].where((s) => s.isNotEmpty).join(' · ');
    return ListTile(
      leading: Icon(r.playable ? Icons.play_circle_outline : Icons.folder_outlined),
      title: Text(r.start.isEmpty ? r.route : r.start),
      subtitle: Text(details),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RoutePage(api: widget.api, route: r)),
      ),
    );
  }
}
