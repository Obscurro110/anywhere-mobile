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
    // 当前助手带来的预设，用来在 chip 上标一个「预设」来源
    final preset = state.activePrompt;

    /// 某一项是否正好等于助手预设（是的话说明"这一项来自助手"）
    bool fromPresetModel() =>
        preset != null && preset.model.isNotEmpty && preset.model == opts.model;
    bool fromPresetEffort() =>
        preset != null &&
        preset.reasoningEffort.isNotEmpty &&
        preset.reasoningEffort == opts.reasoningEffort;
    bool fromPresetMcp() =>
        preset != null && preset.mcp.isNotEmpty && _listEq(preset.mcp, opts.mcp);
    bool fromPresetSkills() =>
        preset != null && preset.skills.isNotEmpty && _listEq(preset.skills, opts.skills);

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
              preset: fromPresetModel(),
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
              preset: fromPresetEffort(),
              onTap: () => _pickEffort(context, state),
            ),
            // ---- MCP ----
            _chip(
              context,
              icon: Icons.build_outlined,
              label: 'MCP${(opts.mcp?.isNotEmpty ?? false) ? ' ${opts.mcp!.length}' : ''}',
              active: opts.mcp?.isNotEmpty ?? false,
              preset: fromPresetMcp(),
              onTap: () => _pickMulti(
                context,
                state,
                title: 'MCP 工具',
                items: caps.mcp
                    .map((m) => _MultiItem(
                        id: m.id,
                        label: m.label,
                        // 优先显示电脑端配的说明；停用的也标出来
                        note: [
                          if (!m.enabled) '（电脑端已停用）',
                          m.summary,
                        ].join(' · ')))
                    .toList(),
                selected: {...?opts.mcp},
                apply: (sel) => state.setOptions(opts.copyWith(mcp: sel)),
              ),
            ),
            // ---- Skill ----
            _chip(
              context,
              icon: Icons.extension_outlined,
              label:
                  'Skill${(opts.skills?.isNotEmpty ?? false) ? ' ${opts.skills!.length}' : ''}',
              active: opts.skills?.isNotEmpty ?? false,
              preset: fromPresetSkills(),
              onTap: () => _pickMulti(
                context,
                state,
                title: 'Skill',
                items: caps.skills
                    .map((s) => _MultiItem(
                        id: s.id,
                        label: s.label,
                        // SKILL.md 里的 description，让用户知道这技能是干嘛的
                        note: s.summary))
                    .toList(),
                selected: {...?opts.skills},
                apply: (sel) => state.setOptions(opts.copyWith(skills: sel)),
              ),
            ),
            // ---- 会话压缩（真实配置：自动开关 + 手动压一次）----
            _chip(
              context,
              icon: Icons.compress,
              label: _compactLabel(caps),
              active: caps.compact != null,
              onTap: () => _pickCompact(context, state),
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

  static bool _listEq(List<String> a, List<String>? b) {
    if (b == null || a.length != b.length) return false;
    final sa = [...a]..sort();
    final sb = [...b]..sort();
    for (var i = 0; i < sa.length; i++) {
      if (sa[i] != sb[i]) return false;
    }
    return true;
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
    /// 这一项的值来自「助手预设」，在左侧加一个小圆点提示
    bool preset = false,
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
            padding: EdgeInsets.fromLTRB(preset ? 7 : 10, 6, 10, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preset)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: const BoxDecoration(
                      color: Colors.lightBlueAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
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
          label: '默认（跟随电脑端）',
          subtitle: '不套用任何助手预设',
        ),
        ...caps.prompts.map((p) => _SheetItem<String?>(
              value: p.key,
              label: p.label,
              // 单行摘要，别用 \n（两行会把面板撑得很长）
              subtitle: p.hasPreset ? '预设：${p.presetSummary}' : '无预设',
            )),
      ],
      current: state.options.promptKey,
      onPicked: (v) {
        final applied = state.activePrompt;
        state.applyPrompt(v);
        if (!context.mounted) return;
        final msg = v == null
            ? '已切回电脑端默认助手（下一条消息起生效）'
            : applied != null && applied.hasPreset
                ? '已切换到「${applied.label}」，并套用其预设：${applied.presetSummary}'
                : '已切换到「$v」（下一条消息会开新会话）';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
        ));
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

  // ---- 会话压缩 ----

  static String _compactLabel(Capabilities caps) {
    final c = caps.compact;
    if (c == null) return '压缩';
    return c.autoCompactEnabled ? '压缩 自动' : '压缩 关';
  }

  /// 压缩面板：显示真实配置 + 手动压一次。
  ///
  /// 以前这个 chip 只是切一个本地布尔值，电脑端压根不读 —— 纯摆设。
  /// 现在改成：开关「自动压缩」（真实写到电脑端 per-model 配置）+ 「立即压缩」。
  static void _pickCompact(BuildContext context, AppState state) {
    final caps = state.capabilities;
    final c = caps.compact;
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('电脑端还没上报压缩配置。请确认桌面端已更新到 v1.5.0+ 并点刷新。'),
        duration: Duration(seconds: 4),
      ));
      state.requestCapabilities();
      return;
    }

    final inDesktopConv = state.activeConversationId != null;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('会话压缩',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.auto_mode, color: Colors.lightBlueAccent),
              title: const Text('自动压缩'),
              subtitle: const Text(
                '对话变长时，电脑端自动把前面的内容摘要掉，避免超出上下文',
                style: TextStyle(fontSize: 11.5),
              ),
              trailing: Switch(
                value: c.autoCompactEnabled,
                onChanged: (v) {
                  Navigator.of(ctx).pop();
                  state.setAutoCompact(v, model: c.model);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(v ? '已开启自动压缩' : '已关闭自动压缩'),
                    duration: const Duration(seconds: 2),
                  ));
                },
              ),
            ),
            _kvTile('当前模型', c.model.isEmpty ? '未知' : c.model.split('|').last),
            _kvTile('上下文窗口', c.contextLabel),
            _kvTile(
              '来源',
              c.contextLengthSource == 'manual'
                  ? '手动设置'
                  : (c.contextLengthSource.isEmpty ? '默认' : c.contextLengthSource),
            ),
            if (c.compactPrompt.isNotEmpty)
              _kvTile('自定义摘要提示词', '已设置（${c.compactPrompt.length} 字）'),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.compress),
                  label: const Text('立即压缩一次'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    if (!inDesktopConv) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('请先到「电脑端对话」点开一个会话，再压缩'),
                        duration: Duration(seconds: 3),
                      ));
                      return;
                    }
                    final sent = state.runCompactOnDesktop(state.activeConversationId);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(sent ? '已让电脑端压缩，跑完会自动刷新' : '发送失败'),
                      duration: const Duration(seconds: 3),
                    ));
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                inDesktopConv
                    ? '压缩会把较早的对话替换成一段摘要，电脑端窗口里能还原。'
                    : '提示：压缩必须在电脑端打开的会话里执行。',
                style: const TextStyle(fontSize: 11.5, color: Colors.white38, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _kvTile(String k, String v) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            Text(k, style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
            const Spacer(),
            Flexible(
              child: Text(
                v,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Colors.white),
              ),
            ),
          ],
        ),
      );

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
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
            ),
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
                              subtitle: it.note == null
                                  ? null
                                  : Text(
                                      it.note!,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11.5),
                                    ),
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
                        // 先关面板再应用（原因同 _singleSheet）：
                        // apply() 里的 notifyListeners() 会让 ctx 失效，导致面板关不掉
                        final nav = Navigator.of(ctx);
                        final result = picked.toList();
                        if (nav.canPop()) nav.pop();
                        apply(result);
                      },
                      child: const Text('确定'),
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
        child: ConstrainedBox(
          // 限制最大高度，助手/模型很多时也不会铺满整屏
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
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
                              // 先关面板再执行回调。
                              // 反过来的话，回调里的 notifyListeners() 会先触发重建，
                              // 面板的 ctx 随之失效，Navigator.pop 就关不掉了
                              // （现象：选了助手后面板卡住、点外面也不消失）。
                              final nav = Navigator.of(ctx);
                              final value = it.value;
                              if (nav.canPop()) nav.pop();
                              onPicked(value);
                            },
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
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
