import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';
import 'desktop_capability_edit_screen.dart';

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
  void _openEdit(BuildContext context, AppState state, String? editId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DesktopCapabilityEditPage(kind: widget.kind, editId: editId),
    ));
  }

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

    final items = _buildItems(caps, kind);

    return Scaffold(
      appBar: AppBar(
        title: Text(kind.title),
        actions: [
          // 新建（Skill 没有新建 —— 那是磁盘目录，手机端不建）
          if (kind != CapabilityKind.skills)
            IconButton(
              tooltip: '新建',
              icon: const Icon(Icons.add),
              onPressed: () => _openEdit(context, state, null),
            ),
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

  static List<Widget> _buildItems(Capabilities caps, CapabilityKind kind) {
    switch (kind) {
      case CapabilityKind.prompts:
        return caps.prompts
            .map((p) => _Row(
                  title: p.label.isEmpty ? p.key : p.label,
                  subtitle: _promptSummary(p),
                  icon: Icons.auto_awesome_outlined,
                  details: _promptDetails(p),
                  editId: p.key,
                ))
            .toList();

      case CapabilityKind.models:
        // 服务商列表（电脑端上报的 providers 明细）；老版本电脑端没有
        // providers 时退回「按模型分组」的展示，至少还能看。
        if (caps.providers.isNotEmpty) {
          return caps.providers
              .map((p) => _Row(
                    title: p.name.isEmpty ? p.id : p.name,
                    subtitle: [
                      if (p.modelList.isNotEmpty) '${p.modelList.length} 个模型',
                      if (p.url.isNotEmpty) p.url,
                      if (!p.enable) '已停用',
                      if (p.hasApiKey) '已配置密钥',
                    ].join(' · '),
                    icon: Icons.cloud_outlined,
                    editId: p.id,
                  ))
              .toList();
        }
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
              editId: pid,
            ),
        ];

      case CapabilityKind.mcp:
        return caps.mcp
            .map((s) => _Row(
                  title: s.label.isEmpty ? s.id : s.label,
                  subtitle: s.summary,
                  icon: Icons.extension_outlined,
                  details: _mcpDetails(s),
                  editId: s.id,
                ))
            .toList();

      case CapabilityKind.skills:
        return caps.skills
            .map((k) => _Row(
                  title: k.label.isEmpty ? k.id : k.label,
                  subtitle: k.summary,
                  icon: Icons.psychology_outlined,
                  details: _skillDetails(k),
                  editId: k.id,
                ))
            .toList();
    }
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

  static List<MapEntry<String, String>> _promptDetails(PromptOption p) {
    return [
      MapEntry('标识', p.key),
      if (p.model.isNotEmpty) MapEntry('默认模型', p.model),
      if (p.reasoningEffort.isNotEmpty) MapEntry('思考预算', p.reasoningEffort),
      if (p.type.isNotEmpty) MapEntry('类型', p.type),
      MapEntry('MCP 工具', p.mcp.isEmpty ? '（不限）' : p.mcp.join('、')),
      MapEntry('Skill 技能', p.skills.isEmpty ? '（不限）' : p.skills.join('、')),
    ];
  }

  static List<MapEntry<String, String>> _mcpDetails(McpOption s) {
    return [
      MapEntry('标识', s.id),
      if (s.type.isNotEmpty) MapEntry('连接方式', s.type),
      if (s.command.isNotEmpty) MapEntry('命令', s.command),
      if (s.url.isNotEmpty) MapEntry('地址', s.url),
      if (s.argsCount > 0) MapEntry('参数个数', '${s.argsCount}'),
      if (s.toolCount > 0) MapEntry('工具个数', '${s.toolCount}'),
      MapEntry('是否内置', s.builtin ? '是' : '否'),
      MapEntry('当前状态', s.enabled ? '已启用' : '已停用'),
      if (s.description.isNotEmpty) MapEntry('说明', s.description),
    ];
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
  /// 非空 = 这一行可以点进**编辑页**（优先于详情弹层）
  final String? editId;

  const _Row({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.details,
    this.editId,
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
      trailing: editId != null
          ? const Icon(Icons.edit_outlined, size: 17, color: Colors.white38)
          : (hasDetails
              ? const Icon(Icons.chevron_right, size: 18, color: Colors.white24)
              : null),
      onTap: () {
        if (editId != null) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DesktopCapabilityEditPage(
              kind: _kindOf(context),
              editId: editId,
            ),
          ));
          return;
        }
        if (hasDetails) _showDetails(context, title, details!);
      },
    );
  }

  /// 从祖先里拿 kind（_Row 是静态构建的，拿不到 widget.kind，用 InheritedContext）
  CapabilityKind _kindOf(BuildContext context) {
    final page = context.findAncestorStateOfType<_DesktopCapabilityPageState>();
    return page?.widget.kind ?? CapabilityKind.models;
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
