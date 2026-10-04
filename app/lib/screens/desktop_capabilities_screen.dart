import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';

/// 电脑端能力的**分类**。设置页里每一类一个入口，点进去只看这一类。
enum CapabilityKind {
  prompts, // 助手
  models, // 模型
  mcp, // MCP 工具
  skills, // Skill 技能
}

extension CapabilityKindInfo on CapabilityKind {
  String get title => switch (this) {
        CapabilityKind.prompts => '助手',
        CapabilityKind.models => '模型',
        CapabilityKind.mcp => 'MCP 工具',
        CapabilityKind.skills => 'Skill 技能',
      };

  IconData get icon => switch (this) {
        CapabilityKind.prompts => Icons.auto_awesome,
        CapabilityKind.models => Icons.memory,
        CapabilityKind.mcp => Icons.extension,
        CapabilityKind.skills => Icons.psychology,
      };

  /// 设置页那一行右边的简短计数
  String countText(Capabilities caps) => switch (this) {
        CapabilityKind.prompts => '${caps.prompts.length} 个',
        CapabilityKind.models => '${caps.models.length} 个',
        CapabilityKind.mcp => '${caps.mcp.length} 个',
        CapabilityKind.skills => '${caps.skills.length} 个',
      };

  /// 设置页那一行的副标题（列几个名字，一目了然）
  String summary(Capabilities caps) {
    switch (this) {
      case CapabilityKind.prompts:
        final names = caps.prompts.map((p) => p.label.isEmpty ? p.key : p.label).take(3).toList();
        return names.isEmpty ? '电脑端没有配置助手' : names.join('、');
      case CapabilityKind.models:
        final names = caps.models.map((m) => m.displayName).take(2).toList();
        return names.isEmpty ? '电脑端没有配置模型' : names.join('、');
      case CapabilityKind.mcp:
        final names = caps.mcp.map((s) => s.label.isEmpty ? s.id : s.label).take(3).toList();
        return names.isEmpty ? '电脑端没有配置 MCP' : names.join('、');
      case CapabilityKind.skills:
        final names = caps.skills.map((k) => k.label.isEmpty ? k.id : k.label).take(3).toList();
        return names.isEmpty ? '电脑端没有安装 Skill' : names.join('、');
    }
  }
}

/// 电脑端某一类能力的详情页。
///
/// 以前是一个页面把所有东西堆在一起，还带个「定时任务」（和 ⋮ 菜单重复）。
/// 现在按类别拆开，从设置页分别进入；定时任务不在这里，它有自己的页面。
class DesktopCapabilityPage extends StatefulWidget {
  final CapabilityKind kind;
  const DesktopCapabilityPage({super.key, required this.kind});

  @override
  State<DesktopCapabilityPage> createState() => _DesktopCapabilityPageState();
}

class _DesktopCapabilityPageState extends State<DesktopCapabilityPage> {
  @override
  void initState() {
    super.initState();
    // 进页面刷新一次，保证数据是最新的（能力清单是电脑端主动上报的）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().requestCapabilities();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final caps = state.capabilities;
    final kind = widget.kind;

    final items = _buildItems(context, state, caps, kind);

    return Scaffold(
      appBar: AppBar(
        title: Text(kind.title),
        actions: [
          IconButton(
            tooltip: '重新拉取',
            icon: state.loadingCapabilities
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: state.loadingCapabilities
                ? null
                : () => state.requestCapabilities(),
          ),
        ],
      ),
      body: caps.isEmpty
          ? _EmptyState(onRefresh: state.requestCapabilities)
          : ListView(
              padding: const EdgeInsets.only(top: 6, bottom: 28),
              children: [
                _HintBar(text: _hintFor(kind)),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(
                      child: Text('这一类电脑端还没上报内容',
                          style: TextStyle(fontSize: 12.5, color: Colors.white38)),
                    ),
                  )
                else
                  ...items,
              ],
            ),
    );
  }

  static String _hintFor(CapabilityKind k) => switch (k) {
        CapabilityKind.prompts => '电脑端「快捷助手」；手机上选哪个就用哪套配置',
        CapabilityKind.models => '显示为「服务商|模型名」',
        CapabilityKind.mcp => '电脑端已配置的 MCP 服务，点开看连接方式与工具',
        CapabilityKind.skills => '电脑端 skills 目录里的技能，点开看说明与可用工具',
      };

  List<Widget> _buildItems(
      BuildContext context, AppState state, Capabilities caps, CapabilityKind kind) {
    switch (kind) {
      case CapabilityKind.prompts:
        return caps.prompts.map((p) {
          final selected = state.options.promptKey == p.key;
          return _Row(
            title: p.label.isEmpty ? p.key : p.label,
            subtitle: _promptSummary(p),
            icon: Icons.auto_awesome_outlined,
            details: _promptDetails(p, caps),
            selected: selected,
            actionLabel: selected ? null : '选用',
            onAction: selected ? null : () => state.applyPrompt(p.key),
          );
        }).toList();

      case CapabilityKind.models:
        if (caps.providers.isNotEmpty) {
          return caps.providers.map((p) {
            // 当前选中的模型是否属于这个服务商
            final cur = state.options.model ?? '';
            final curInThis = cur.isNotEmpty && cur.startsWith('${p.id}|');
            return _Row(
              title: p.name.isEmpty ? p.id : p.name,
              subtitle: [
                if (p.modelList.isNotEmpty)
                  '${p.modelList.length} 个模型 · ${p.modelList.take(2).join('、')}'
                else
                  '暂无模型',
                if (p.apiType.isNotEmpty) p.apiType,
                if (!p.enable) '已停用',
                if (p.hasApiKey) '密钥已配置',
              ].join(' · '),
              icon: Icons.cloud_outlined,
              selected: curInThis,
              actionLabel: p.modelList.isEmpty ? null : (curInThis ? '已选' : '选模型'),
              onAction: p.modelList.isEmpty
                  ? null
                  : () => _pickModelFromProvider(context, state, p),
            );
          }).toList();
        }
        // 老版本电脑端没有 providers，退回「按模型分组」只读展示
        final groups = <String, List<String>>{};
        final order = <String>[];
        for (final m in caps.models) {
          final pid = m.providerLabel;
          if (!order.contains(pid)) order.add(pid);
          (groups[pid] ??= []).add(m.label);
        }
        return [
          for (final pid in order)
            _Row(
              title: pid,
              subtitle: (groups[pid] ?? const []).join('、'),
              icon: Icons.cloud_outlined,
            ),
        ];

      case CapabilityKind.mcp:
        return caps.mcp.map((s) {
          final cur = state.options.mcp ?? const [];
          final selected = cur.contains(s.id);
          return _Row(
            title: s.label.isEmpty ? s.id : s.label,
            subtitle: s.summary,
            icon: Icons.extension_outlined,
            details: _mcpDetails(s),
            selected: selected,
            actionLabel: selected ? '已选' : '添加',
            onAction: () => _toggleMcp(context, state, s.id),
          );
        }).toList();

      case CapabilityKind.skills:
        return caps.skills.map((k) {
          final cur = state.options.skills ?? const [];
          final selected = cur.contains(k.id);
          return _Row(
            title: k.label.isEmpty ? k.id : k.label,
            subtitle: k.summary,
            icon: Icons.psychology_outlined,
            details: _skillDetails(k),
            selected: selected,
            actionLabel: selected ? '已选' : '添加',
            onAction: () => _toggleSkill(context, state, k.id),
          );
        }).toList();
    }
  }

  /// 从某个服务商里挑一个模型作为当前会话模型。
  void _pickModelFromProvider(
      BuildContext context, AppState state, ProviderOption p) {
    if (p.modelList.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(p.name.isEmpty ? p.id : p.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            for (final model in p.modelList)
              ListTile(
                dense: true,
                leading: const Icon(Icons.smart_toy_outlined,
                    size: 18, color: Colors.white38),
                title: Text(model, style: const TextStyle(fontSize: 14)),
                trailing: (state.options.model == '${p.id}|$model')
                    ? const Icon(Icons.check, color: Colors.greenAccent)
                    : null,
                onTap: () {
                  state.setOptions(
                      state.options.copyWith(model: '${p.id}|$model'));
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _toggleMcp(BuildContext context, AppState state, String id) {
    final cur = Set<String>.from(state.options.mcp ?? const []);
    if (cur.contains(id)) {
      cur.remove(id);
    } else {
      cur.add(id);
    }
    state.setOptions(state.options.copyWith(mcp: cur.toList()));
  }

  void _toggleSkill(BuildContext context, AppState state, String id) {
    final cur = Set<String>.from(state.options.skills ?? const []);
    if (cur.contains(id)) {
      cur.remove(id);
    } else {
      cur.add(id);
    }
    state.setOptions(state.options.copyWith(skills: cur.toList()));
  }

  /// 把电脑端的「providerId|模型名」显示成「服务商|模型名」；
  /// 服务商名从模型列表里查（查不到就退回原始值）。
  static String _modelDisplay(Capabilities caps, String raw) {
    if (raw.isEmpty) return raw;
    for (final m in caps.models) {
      if (m.value == raw) return m.displayName;
    }
    final parts = raw.split('|');
    if (parts.length > 1) return parts[1];
    return raw;
  }

  static String _promptSummary(PromptOption p) {
    final bits = <String>[];
    if (p.model.isNotEmpty) {
      final parts = p.model.split('|');
      bits.add(parts.length > 1 ? parts[1] : p.model);
    }
    if (p.mcp.isNotEmpty) bits.add('MCP ${p.mcp.length}');
    if (p.skills.isNotEmpty) bits.add('Skill ${p.skills.length}');
    return bits.isEmpty ? '未限定模型与工具' : bits.join(' · ');
  }

  static List<MapEntry<String, String>> _promptDetails(
      PromptOption p, Capabilities caps) {
    return [
      MapEntry('标识', p.key),
      if (p.model.isNotEmpty)
        MapEntry('默认模型', _modelDisplay(caps, p.model)),
      if (p.reasoningEffort.isNotEmpty) MapEntry('思考预算', p.reasoningEffort),
      if (p.type.isNotEmpty) MapEntry('类型', p.type),
      MapEntry('MCP 工具', p.mcp.isEmpty ? '（不限）' : p.mcp.join('、')),
      MapEntry('Skill 技能', p.skills.isEmpty ? '（不限）' : p.skills.join('、')),
    ];
  }

  static List<MapEntry<String, String>> _mcpDetails(McpOption s) {
    final rows = <MapEntry<String, String>>[
      MapEntry('标识', s.id),
      if (s.description.isNotEmpty) MapEntry('说明', s.description),
      if (s.type.isNotEmpty) MapEntry('连接方式', s.type),
      if (s.command.isNotEmpty) MapEntry('命令', s.command),
      if (s.url.isNotEmpty) MapEntry('地址', s.url),
      if (s.args.isNotEmpty) MapEntry('参数', s.args.join(' ')),
      if (s.env.isNotEmpty)
        MapEntry('环境变量', s.env.entries.map((e) => '${e.key}=${e.value}').join('\n')),
      if (s.headers.isNotEmpty)
        MapEntry('请求头', s.headers.entries.map((e) => '${e.key}=${e.value}').join('\n')),
      if (s.authType.isNotEmpty && s.authType != 'none') MapEntry('认证', s.authType),
      if (s.timeoutSeconds > 0) MapEntry('超时', '${s.timeoutSeconds} 秒'),
      if (s.tags.isNotEmpty) MapEntry('标签', s.tags.join('、')),
      if (s.toolCount > 0) MapEntry('工具数', '${s.toolCount}'),
      MapEntry('状态', s.enabled ? '已启用' : '已停用'),
    ];
    return rows;
  }

  static List<MapEntry<String, String>> _skillDetails(SkillOption k) {
    return [
      MapEntry('标识', k.id),
      if (k.description.isNotEmpty) MapEntry('说明', k.description),
      if (k.context.isNotEmpty) MapEntry('上下文', k.context),
      MapEntry('可用工具',
          k.allowedTools.isEmpty ? '（不限）' : k.allowedTools.join('、')),
      MapEntry('可手动调用', k.userInvocable ? '是' : '否'),
      MapEntry('当前状态', k.disabled ? '已停用' : '已启用'),
    ];
  }
}

class _HintBar extends StatelessWidget {
  final String text;
  const _HintBar({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(text,
          style: const TextStyle(fontSize: 11.5, color: Colors.white38, height: 1.4)),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<MapEntry<String, String>>? details;

  /// 当前会话是否已选用这一项（选中态：尾部打勾、不再显示操作按钮）
  final bool selected;

  /// 尾部操作按钮的文字（如「选用 / 选模型 / 添加」）。null = 无操作。
  final String? actionLabel;

  /// 尾部操作按钮的回调（选择 / 切换）。
  final VoidCallback? onAction;

  const _Row({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.details,
    this.selected = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final hasDetails = details != null && details!.isNotEmpty;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: Colors.white38),
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
      trailing: _trailing(hasDetails),
      onTap: hasDetails ? () => _showDetails(context, title, details!) : null,
    );
  }

  Widget? _trailing(bool hasDetails) {
    if (onAction != null) {
      if (selected) {
        return const Icon(Icons.check_circle, size: 19, color: Colors.greenAccent);
      }
      return TextButton(
        onPressed: onAction,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(actionLabel ?? '选择', style: const TextStyle(fontSize: 13)),
      );
    }
    if (hasDetails) {
      return const Icon(Icons.chevron_right, size: 18, color: Colors.white24);
    }
    return null;
  }

  static void _showDetails(
      BuildContext context, String title, List<MapEntry<String, String>> rows) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.66,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: rows
                      .map((e) => Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 84,
                                  child: Text(e.key,
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.white38)),
                                ),
                                Expanded(
                                  child: SelectableText(e.value,
                                      style: const TextStyle(fontSize: 12.5)),
                                ),
                              ],
                            ),
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

class _EmptyState extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44, color: Colors.white24),
            const SizedBox(height: 14),
            const Text('还没拿到电脑端能力',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              '请确认：\n· 电脑端 relay 程序已启动并连上中继\n· 手机与电脑端用的是同一个用户 ID / 令牌',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white54, height: 1.5),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新拉取'),
            ),
          ],
        ),
      ),
    );
  }
}
