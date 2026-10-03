import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 会话参数工具条：助手 / 模型 / 思考预算 / MCP / Skill / 压缩。
///
/// 放在输入框正上方（参考电脑端 ChatInput 的布局），
/// 选中的参数会随每条消息一起发给电脑端。
class ConversationOptionsBar extends StatelessWidget {
  const ConversationOptionsBar({super.key});

  static const _effortLabels = {
    'default': '默认',
    'none': '关闭',
    'low': '低',
    'medium': '中',
    'high': '高',
    'xhigh': '很高',
    'max': '最大',
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final caps = state.capabilities;
    final opts = state.options;

    return Container(
      color: const Color(0xFF141821),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // ---- 快捷助手 ----
            _chip(
              context,
              icon: Icons.auto_awesome,
              label: _promptLabel(caps, opts.promptKey),
              active: opts.promptKey != null && opts.promptKey!.isNotEmpty,
              onTap: () => _pickPrompt(context, state),
            ),
            // ---- 模型 ----
            _chip(
              context,
              icon: Icons.memory,
              label: _modelLabel(caps, opts.model),
              active: (opts.model ?? '').isNotEmpty,
              onTap: () => _pickModel(context, state),
            ),
            // ---- 思考预算 ----
            _chip(
              context,
              icon: Icons.psychology_outlined,
              label:
                  '思考 ${_effortLabels[opts.reasoningEffort ?? 'default'] ?? opts.reasoningEffort}',
              active:
                  opts.reasoningEffort != null && opts.reasoningEffort != 'default',
              onTap: () => _pickEffort(context, state),
            ),
            // ---- MCP ----
            _chip(
              context,
              icon: Icons.build_outlined,
              label: 'MCP${(opts.mcp?.isNotEmpty ?? false) ? ' ${opts.mcp!.length}' : ''}',
              active: opts.mcp?.isNotEmpty ?? false,
              onTap: () => _pickMulti(
                context,
                state,
                title: 'MCP 工具',
                items: caps.mcp
                    .map((m) => _MultiItem(id: m.id, label: m.label, note: m.enabled ? null : '（电脑端已停用）'))
                    .toList(),
                selected: {...?opts.mcp},
                apply: (sel) => state.setOptions(opts.copyWith(mcp: sel)),
              ),
            ),
            // ---- Skill ----
            _chip(
              context,
              icon: Icons.extension_outlined,
              label: 'Skill${(opts.skills?.isNotEmpty ?? false) ? ' ${opts.skills!.length}' : ''}',
              active: opts.skills?.isNotEmpty ?? false,
              onTap: () => _pickMulti(
                context,
                state,
                title: 'Skill',
                items: caps.skills
                    .map((s) => _MultiItem(id: s.id, label: s.label))
                    .toList(),
                selected: {...?opts.skills},
                apply: (sel) => state.setOptions(opts.copyWith(skills: sel)),
              ),
            ),
            // ---- 会话压缩 ----
            _chip(
              context,
              icon: Icons.compress,
              label: opts.compress == true ? '压缩 开' : '压缩',
              active: opts.compress == true,
              onTap: () =>
                  state.setOptions(opts.copyWith(compress: !(opts.compress ?? false))),
            ),
            IconButton(
              tooltip: '刷新电脑端能力',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: state.requestCapabilities,
            ),
          ],
        ),
      ),
    );
  }

  // ---- labels ----
  static String _promptLabel(Capabilities caps, String? key) {
    if (key == null || key.isEmpty) return '助手：默认';
    final hit = caps.prompts.where((p) => p.key == key);
    return '助手：${hit.isNotEmpty ? hit.first.label : key}';
  }

  static String _modelLabel(Capabilities caps, String? value) {
    if (value == null || value.isEmpty) return '默认模型';
    final hit = caps.models.where((m) => m.value == value);
    if (hit.isNotEmpty) return hit.first.label;
    final parts = value.split('|');
    return parts.length > 1 ? parts[1] : value;
  }

  // ---- chip ----
  static Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: active ? const Color(0xFF2C3550) : const Color(0xFF1B1F2B),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: active ? Colors.lightBlueAccent : Colors.white54),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: active ? Colors.white : Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- pickers ----
  static void _needCapabilities(BuildContext context, AppState state) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('电脑端还没上报该列表，请确认电脑端「手机互通」在线后点刷新')),
    );
    state.requestCapabilities();
  }

  static void _pickPrompt(BuildContext context, AppState state) {
    final caps = state.capabilities;
    if (caps.prompts.isEmpty) {
      _needCapabilities(context, state);
      return;
    }
    _singleSheet<String?>(
      context,
      title: '选择快捷助手',
      items: [
        const _SheetItem<String?>(
          value: null,
          label: '默认（使用电脑端当前配置）',
          subtitle: '不套用任何助手预设',
        ),
        ...caps.prompts.map((p) => _SheetItem<String?>(
              value: p.key,
              label: p.label,
              // 让用户一眼看到这个助手会带来哪些设置
              subtitle: p.hasPreset
                  ? '预设：${p.presetSummary}\n$p.key'
                  : '无预设 · $p.key',
            )),
      ],
      current: state.options.promptKey,
      onPicked: (v) {
        state.applyPrompt(v);
        if (!context.mounted) return;
        final applied = state.activePrompt;
        final msg = v == null
            ? '已切回电脑端默认助手（下一条消息起新生效）'
            : applied != null && applied.hasPreset
                ? '已切换到「${applied.label}」，并套用其预设：${applied.presetSummary}'
                : '已切换到「$v」（下一条消息会开新会话）';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      },
    );
  }

  static void _pickModel(BuildContext context, AppState state) {
    final caps = state.capabilities;
    if (caps.models.isEmpty) {
      _needCapabilities(context, state);
      return;
    }
    _singleSheet<String?>(
      context,
      title: '选择模型',
      items: [
        const _SheetItem<String?>(value: null, label: '默认（跟随电脑端）'),
        ...caps.models.map((m) => _SheetItem<String?>(
              value: m.value,
              label: m.label,
              subtitle: m.provider,
            )),
      ],
      current: state.options.model,
      onPicked: (v) => state.setOptions(state.options.copyWith(model: v)),
    );
  }

  static void _pickEffort(BuildContext context, AppState state) {
    final list = state.capabilities.reasoningEffortOptions.isEmpty
        ? const ['default', 'none', 'low', 'medium', 'high', 'xhigh', 'max']
        : state.capabilities.reasoningEffortOptions;
    _singleSheet<String?>(
      context,
      title: '思考预算',
      items: [
        const _SheetItem<String?>(value: null, label: '默认（跟随电脑端）'),
        ...list.map((e) => _SheetItem<String?>(value: e, label: _effortLabels[e] ?? e)),
      ],
      current: state.options.reasoningEffort,
      onPicked: (v) => state.setOptions(state.options.copyWith(reasoningEffort: v)),
    );
  }

  static void _pickMulti(
    BuildContext context,
    AppState state, {
    required String title,
    required List<_MultiItem> items,
    required Set<String> selected,
    required void Function(List<String>) apply,
  }) {
    if (items.isEmpty) {
      _needCapabilities(context, state);
      return;
    }
    final picked = {...selected};
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: items
                      .map((it) => CheckboxListTile(
                            dense: true,
                            value: picked.contains(it.id),
                            title: Text(it.label),
                            subtitle: it.note == null ? null : Text(it.note!),
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                picked.add(it.id);
                              } else {
                                picked.remove(it.id);
                              }
                            }),
                          ))
                      .toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      apply(picked.toList());
                      Navigator.pop(ctx);
                    },
                    child: const Text('确定'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _singleSheet<T>(
    BuildContext context, {
    required String title,
    required List<_SheetItem<T>> items,
    required T current,
    required ValueChanged<T> onPicked,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: items
                    .map((it) => ListTile(
                          dense: true,
                          title: Text(it.label),
                          subtitle: it.subtitle == null ? null : Text(it.subtitle!),
                          trailing: it.value == current
                              ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                              : null,
                          onTap: () {
                            onPicked(it.value);
                            Navigator.pop(ctx);
                          },
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  const _SheetItem({required this.value, required this.label, this.subtitle});
}

class _MultiItem {
  final String id;
  final String label;
  final String? note;
  const _MultiItem({required this.id, required this.label, this.note});
}
