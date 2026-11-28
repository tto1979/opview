// one drive: the preview video (qcamera, HLS) and its segments, with downloads
// TOP plays the whole drive as one playlist; dashy plays one segment at a time

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:opview/services/wake_lock_service.dart' as wake_lock;
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';
import 'package:opview/top/services/downloader.dart';

const _segmentSeconds = 60;
const _fileOrder = ['qcamera.ts', 'fcamera.hevc', 'ecamera.hevc', 'dcamera.hevc', 'qlog.zst', 'qlog', 'rlog.zst', 'rlog'];

class RoutePage extends StatefulWidget {
  final DeviceApi api;
  final RouteInfo route;

  const RoutePage({super.key, required this.api, required this.route});

  @override
  State<RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<RoutePage> {
  VideoPlayerController? _controller;
  String? _playerError;
  Segment? _single; // dashy: the segment being played

  late final List<Segment> _playable = widget.route.segments.where((s) => s.playable).toList();

  @override
  void initState() {
    super.initState();
    wake_lock.setKeepScreenOn(true);
    _start();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _start() {
    if (_playable.isEmpty) return;
    if (widget.api.hasRouteApi) {
      _open(widget.api.routeManifest(widget.route.route));
    } else {
      _openSegment(_playable.first);
    }
  }

  void _openSegment(Segment s) {
    _single = s;
    _open(widget.api.fileManifest('${s.name}/qcamera.ts'));
  }

  Future<void> _open(Uri url, {Duration start = Duration.zero}) async {
    final old = _controller;
    old?.removeListener(_onTick);
    final c = VideoPlayerController.networkUrl(url, formatHint: VideoFormat.hls);
    setState(() {
      _controller = c;
      _playerError = null;
    });
    // the old player is still on screen until the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    try {
      await c.initialize();
      if (!mounted || _controller != c) return;
      c.addListener(_onTick);
      if (start > Duration.zero) await c.seekTo(start);
      await c.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted || _controller != c) return;
      setState(() => _playerError = '$e');
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    // dashy: on to the next segment at the end of this one
    final single = _single;
    if (single != null && v.isInitialized && !v.isPlaying && v.duration > Duration.zero && v.position >= v.duration) {
      final next = _playable.indexOf(single) + 1;
      if (next > 0 && next < _playable.length) {
        _openSegment(_playable[next]);
        return;
      }
    }
    setState(() {});
  }

  Segment? get _currentSegment {
    if (_single != null) return _single;
    final c = _controller;
    if (c == null || !c.value.isInitialized || _playable.isEmpty) return null;
    final i = c.value.position.inSeconds ~/ _segmentSeconds;
    return _playable[i.clamp(0, _playable.length - 1).toInt()];
  }

  void _play(Segment s) {
    if (!s.playable) return;
    if (!widget.api.hasRouteApi) {
      _openSegment(s);
      return;
    }
    final c = _controller;
    final start = Duration(seconds: _playable.indexOf(s) * _segmentSeconds);
    if (c != null && c.value.isInitialized) {
      c.seekTo(start);
      c.play();
    } else {
      _open(widget.api.routeManifest(widget.route.route), start: start);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// TOP refuses downloads while driving: say so instead of a failed download
  Future<bool> _offroadOrSay() async {
    if (!widget.api.needsPairing) return true;
    try {
      if (await widget.api.isOffroad()) return true;
      _snack(T.onroadNoDownload);
    } on ApiException catch (e) {
      _snack(T.loadFailed(e.message));
    }
    return false;
  }

  /// queues one file with the system download manager, null if it couldn't
  Future<QueuedDownload?> _queue(Segment s, String name) async {
    try {
      return await download(widget.api.downloadUrl('${s.name}/$name'), '${s.name}_$name');
    } on DownloadException catch (e) {
      _snack(T.downloadFailed(e.message));
      return null;
    }
  }

  void _snackWithDownloads(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: T.viewDownloads, onPressed: openDownloads),
    ));
  }

  /// starts the downloads and says how they ended: where the files are, or why they failed
  Future<void> _startDownloads(List<(Segment, String)> files) async {
    final queued = <QueuedDownload>[];
    for (final (s, name) in files) {
      final q = await _queue(s, name);
      if (q == null) break;
      queued.add(q);
    }
    if (queued.isEmpty) return;
    _snackWithDownloads(T.downloading(queued.length == 1 ? queued.first.path : queued.first.folder));

    final pending = {for (final q in queued) q.id};
    final failed = <int>[];
    var done = 0;
    final end = DateTime.now().add(const Duration(minutes: 30));
    while (pending.isNotEmpty && mounted && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(seconds: 2));
      for (final id in pending.toList()) {
        final status = await downloadStatus(id);
        if (!status.ended) continue;
        pending.remove(id);
        if (status.state == DownloadState.done) {
          done++;
        } else if (status.state == DownloadState.failed) {
          failed.add(status.reason);
        }
      }
    }
    if (failed.isNotEmpty) {
      _snackWithDownloads(queued.length == 1
          ? T.downloadFailed(T.downloadReason(failed.first))
          : T.downloadsFailed(failed.length, queued.length, T.downloadReason(failed.first)));
    } else if (done == queued.length) {
      _snackWithDownloads(queued.length == 1 ? T.downloaded(queued.first.path) : T.downloadedMany(done, queued.first.folder));
    }
  }

  Future<void> _downloadRlog(Segment s) async {
    if (!await _offroadOrSay()) return;
    final String? name;
    try {
      name = rlogOf(await widget.api.segmentFiles(s));
    } on ApiException catch (e) {
      _snack(T.loadFailed(e.message));
      return;
    }
    if (name == null) {
      _snack(T.noRlog);
      return;
    }
    await _startDownloads([(s, name)]);
  }

  /// every segment's rlog, after showing how many files and how big
  Future<void> _downloadAllRlogs() async {
    if (!await _offroadOrSay()) return;
    final picked = <(Segment, String, int)>[];
    for (final s in widget.route.segments) {
      try {
        final files = await widget.api.segmentFiles(s);
        final name = rlogOf(files);
        if (name != null) picked.add((s, name, files[name] ?? 0));
      } on ApiException {
        continue;
      }
    }
    if (picked.isEmpty) {
      _snack(T.noRlog);
      return;
    }
    if (!mounted) return;
    final total = picked.fold<int>(0, (sum, p) => sum + p.$3);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(T.allRlogsTitle),
        content: Text(T.rlogFiles(picked.length, formatBytes(total))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(T.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(T.download)),
        ],
      ),
    );
    if (ok != true) return;
    await _startDownloads([for (final (s, name, _) in picked) (s, name)]);
  }

  Future<void> _downloadSheet(Segment s) async {
    if (!await _offroadOrSay()) return;
    Map<String, int> files;
    try {
      files = await widget.api.segmentFiles(s);
    } on ApiException catch (e) {
      _snack(T.loadFailed(e.message));
      return;
    }
    if (!mounted) return;
    final names = files.keys.toList()..sort(_compareFiles);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text('${T.download} · ${T.segment(s.index)}', style: Theme.of(context).textTheme.titleMedium)),
            for (final name in names)
              ListTile(
                leading: const Icon(Icons.download),
                title: Text(T.fileLabel(name)),
                subtitle: Text([name, formatBytes(files[name] ?? 0)].where((t) => t.isNotEmpty).join(' · ')),
                onTap: () => Navigator.pop(context, name),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _startDownloads([(s, picked)]);
  }

  static int _compareFiles(String a, String b) {
    final ia = _fileOrder.indexOf(a);
    final ib = _fileOrder.indexOf(b);
    if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
    if (ia >= 0) return -1;
    if (ib >= 0) return 1;
    return a.compareTo(b);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: Text(r.start.isEmpty ? r.route : r.start),
        actions: [
          IconButton(icon: const Icon(Icons.folder_open), tooltip: T.viewDownloads, onPressed: openDownloads),
          TextButton.icon(onPressed: _downloadAllRlogs, icon: const Icon(Icons.download), label: Text(T.allRlogs)),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(child: _player()),
            const VerticalDivider(width: 1),
            SizedBox(width: 320, child: _segmentList()),
          ],
        ),
      ),
    );
  }

  Widget _player() {
    final c = _controller;
    Widget body;
    if (_playable.isEmpty) {
      body = _message(T.notPlayable);
    } else if (_playerError != null) {
      body = _message(T.loadFailed(_playerError!));
    } else if (c == null || !c.value.isInitialized) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => c.value.isPlaying ? c.pause() : c.play(),
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(c),
                      if (c.value.isBuffering) const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
            ),
          ),
          VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6)),
          Row(
            children: [
              IconButton(
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
              ),
              Text('${_clock(c.value.position)} / ${_clock(c.value.duration)}'),
            ],
          ),
        ],
      );
    }
    return ColoredBox(color: Colors.black, child: body);
  }

  Widget _message(String text) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center)),
      );

  Widget _segmentList() {
    final current = _currentSegment;
    return ListView.builder(
      itemCount: widget.route.segments.length,
      itemBuilder: (context, i) {
        final s = widget.route.segments[i];
        return ListTile(
          dense: true,
          selected: identical(s, current),
          leading: Icon(s.playable ? Icons.play_arrow : Icons.videocam_off_outlined, size: 20),
          title: Text(T.segment(s.index)),
          subtitle: s.size > 0 ? Text(formatBytes(s.size)) : null,
          onTap: s.playable ? () => _play(s) : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // rlog in one tap (TOP knows the files already, dashy lists them on tap)
              if (s.files == null || rlogOf(s.files!) != null)
                Tooltip(
                  message: T.downloadRlog,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => _downloadRlog(s),
                    child: const Text('rlog'),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: T.download,
                onPressed: () => _downloadSheet(s),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
