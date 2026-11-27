// device settings in dashy's format: toggles, choices, numbers, car model
// names, descriptions and why something can't be changed now come translated from the device

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/top/api/device_api.dart';
import 'package:opview/top/l10n.dart';

class SettingsView extends StatefulWidget {
  final DeviceApi api;
  final VoidCallback onUnpaired;

  const SettingsView({super.key, required this.api, required this.onUnpaired});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  List<SettingSection>? _sections;
  String? _error;
  final _busy = <String>{};
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sections = await widget.api.settings();
      if (!mounted) return;
      setState(() {
        _sections = sections;
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

  Future<void> _set(SettingItem item, dynamic value) async {
    setState(() => _busy.add(item.key));
    try {
      await widget.api.setParam(item.key, value);
      await _load(); // other settings can change with this one (e.g. NNFF and lag learning)
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.unpaired) {
        widget.onUnpaired();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.status == 0 ? T.networkError : e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(item.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    if (sections == null) {
      if (_error == null) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(T.loadFailed(_error!)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                setState(() => _error = null);
                _load();
              },
              child: Text(T.retry),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          for (final section in sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                section.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ),
            for (final item in section.items) _item(item),
          ],
        ],
      ),
    );
  }

  Widget _item(SettingItem item) {
    final theme = Theme.of(context);
    final canChange = item.enabled && !_busy.contains(item.key);
    final description = htmlToText(item.description);
    final expanded = _expanded.contains(item.key);

    final subtitle = <Widget>[
      if (item.disabledReason != null)
        Text(item.disabledReason!, style: TextStyle(color: theme.colorScheme.tertiary)),
      if (description.isNotEmpty)
        Text(
          description,
          maxLines: expanded ? null : 2,
          overflow: expanded ? null : TextOverflow.ellipsis,
        ),
    ];

    void toggleDescription() => setState(() {
          if (!_expanded.remove(item.key)) _expanded.add(item.key);
        });

    VoidCallback? onTap = description.isEmpty ? null : toggleDescription;
    Widget? trailing;

    switch (item.type) {
      case 'toggle_item':
        trailing = Switch(value: item.value == true, onChanged: canChange ? (v) => _set(item, v) : null);
      case 'text_spin_button_item':
        final index = item.value is num ? (item.value as num).toInt() : 0;
        trailing = DropdownButton<int>(
          value: index >= 0 && index < item.options.length ? index : null,
          underline: const SizedBox.shrink(),
          items: [
            for (var i = 0; i < item.options.length; i++) DropdownMenuItem(value: i, child: Text(item.options[i])),
          ],
          onChanged: canChange
              ? (v) {
                  if (v != null && v != index) _set(item, v);
                }
              : null,
        );
      case 'spin_button_item':
      case 'double_spin_button_item':
        trailing = _spinner(item, canChange);
      case 'select_item':
        trailing = _valueText(item.value);
        if (canChange) {
          onTap = () async {
            final picked = await showSearchPicker(context, item.title, item.options, '${item.value}');
            if (picked != null && picked != '${item.value}') _set(item, picked);
          };
        }
      case 'text_input_item':
        trailing = _valueText(item.value);
        if (canChange) {
          onTap = () async {
            final text = await _askText(item);
            if (text != null && text != '${item.value ?? ''}') _set(item, text);
          };
        }
      default:
        trailing = _valueText(item.value);
    }

    return ListTile(
      title: Text(item.title, style: canChange ? null : TextStyle(color: theme.disabledColor)),
      subtitle: subtitle.isEmpty
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: subtitle),
      trailing: _busy.contains(item.key)
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : trailing,
      onTap: onTap,
    );
  }

  Widget _valueText(dynamic value) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          value == null ? '' : '$value'.replaceAll('_', ' '),
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
        ),
      );

  Widget _spinner(SettingItem item, bool canChange) {
    final isDouble = item.type == 'double_spin_button_item';
    final value = item.value is num ? item.value as num : item.minVal;
    final decimals = isDouble ? _decimals(item.step) : 0;

    void change(int direction) {
      var next = value + direction * item.step;
      if (next < item.minVal) next = item.minVal;
      if (next > item.maxVal) next = item.maxVal;
      if (next == value) return;
      _set(item, isDouble ? double.parse(next.toStringAsFixed(decimals)) : next.round());
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: canChange && value > item.minVal ? () => change(-1) : null,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 64),
          child: Text('${value.toStringAsFixed(decimals)}${item.suffix}', textAlign: TextAlign.center),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: canChange && value < item.maxVal ? () => change(1) : null,
        ),
      ],
    );
  }

  static int _decimals(num step) {
    final text = step.toString();
    final dot = text.indexOf('.');
    return dot < 0 ? 0 : min(text.length - dot - 1, 4);
  }

  Future<String?> _askText(SettingItem item) {
    final controller = TextEditingController(text: '${item.value ?? ''}');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(item.title),
        content: TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(T.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(T.ok)),
        ],
      ),
    );
  }
}

/// long option lists (the car model): a dialog with a search box
Future<String?> showSearchPicker(BuildContext context, String title, List<String> options, String current) {
  return showDialog<String>(
    context: context,
    builder: (context) => _SearchPicker(title: title, options: options, current: current),
  );
}

class _SearchPicker extends StatefulWidget {
  final String title;
  final List<String> options;
  final String current;

  const _SearchPicker({required this.title, required this.options, required this.current});

  @override
  State<_SearchPicker> createState() => _SearchPickerState();
}

class _SearchPickerState extends State<_SearchPicker> {
  String _query = '';

  static String _label(String option) => option.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase().replaceAll('_', ' ');
    final filtered = widget.options.where((o) => _label(o).toLowerCase().contains(query)).toList();
    final size = MediaQuery.of(context).size;
    return Dialog(
      child: SizedBox(
        width: 560,
        height: size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: '${T.search} ${widget.title}',
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  title: Text(_label(filtered[i])),
                  selected: filtered[i] == widget.current,
                  onTap: () => Navigator.pop(context, filtered[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
