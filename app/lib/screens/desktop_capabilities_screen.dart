import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';

/// 「电脑端能力」详情页。
///
/// 以前设置页那一行只写「助手 3 · 模型 5 / MCP 2 · Skill 4」——既看不出
/// 到底有哪些，点一下也只是重新拉一次，没地方看细节。
/// 这页把电脑端上报的能力**分组展开**，点每一项还能看说明。
class DesktopCapabilitiesPage extends StatefulWidget {
  const DesktopCapabilitiesPage({super.key});

  @override
  State<DesktopCapabilitiesPage> createState() => _DesktopCapabilitiesPageState();
}

class _DesktopCapabilitiesPageState extends State<DesktopCapabilitiesPage> {
  @override
  void initState() {
    super.initState();
    // 进页面就刷新一次，保证看到的是最新的
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().requestCapabilities();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final caps = state.capabilities;

    return Scaffold(
      appBar: AppBar(
        title: const Text('电脑端能力'),
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
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                _VersionCard(caps: caps),
                _Section(
                  icon: Icons.auto_awesome,
                  title: '助手',
                  hint: '电脑端「快捷助手」；手机上选哪个就用哪套配置',
                  count: caps.prompts.length,
                  children: caps.prompts
                      .map((p) => _Row(
                            title: p.label.isEmpty ? p.key : p.label,
                            subtitle: _promptSummary(p),
                            icon: Icons.auto_awesome_outlined,
                          ))
                      .toList(),
                ),
                _Section(
                  icon: Icons.memory,
                  title: '模型',
                  hint: '显示为「服务商|模型名」',
                  count: caps.models.length,
                  children: caps.models
                      .map((m) => _Row(
                            title: m.displayName,
                            subtitle: m.value,
                            icon: Icons.smart_toy_outlined,
                          ))
                      .toList(),
                ),
                _Section(
                  icon: Icons.extension,
                  title: 'MCP 工具',
                  hint: '电脑端已配置的 MCP 服务',
                  count: caps.mcp.length,
                  children: caps.mcp
                      .map((s) => _Row(
                            title: s.label.isEmpty ? s.id : s.label,
                            subtitle: s.summary,
                            icon: Icons.extension_outlined,
                            // 每项都能点开看完整说明
                            details: _mcpDetails(s),
                          ))
                      .toList(),
                ),
                _Section(
                  icon: Icons.psychology,
                  title: 'Skill 技能',
                  hint: '电脑端 skills 目录里的技能',
                  count: caps.skills.length,
                  children: caps.skills
                      .map((k) => _Row(
                            title: k.label.isEmpty ? k.id : k.label,
                            subtitle: k.summary,
                            icon: Icons.psychology_outlined,
                            details: _skillDetails(k),
                          ))
                      .toList(),
                ),
                _Section(
                  icon: Icons.schedule,
                  title: '定时任务',
                  hint: '在「定时任务」页里可以管理',
                  count: caps.tasks.length,
                  children: caps.tasks
                      .map((t) => _Row(
                            title: t.label.isEmpty ? t.id : t.label,
                            subtitle: t.enabled ? '已启用' : '已停用',
                            icon: Icons.schedule_outlined,
                          ))
                      .toList(),
                ),
              ],
            ),
    );
  }

  static String _promptSummary(PromptOption p) {
    final bits = <String>[];
    if (p.model.isNotEmpty) bits.add(_shortModel(p.model));
    if (p.mcp.isNotEmpty) bits.add('MCP ${p.mcp.length}');
    if (p.skills.isNotEmpty) bits.add('Skill ${p.skills.length}');
    return bits.isEmpty ? '未限定模型与工具' : bits.join(' · ');
  }

  static String _shortModel(String v) {
    final parts = v.split('|');
    return parts.length > 1 ? parts[1] : v;
  }

  static List<MapEntry<String, String>> _mcpDetails(McpOption s) {
    return [
      if (s.type.isNotEmpty) MapEntry('连接方式', s.type),
      if (s.command.isNotEmpty) MapEntry('命令', s.command),
      if (s.url.isNotEmpty) MapEntry('地址', s.url),
      if (s.argsCount > 0) MapEntry('参数个数', '${s.argsCount}'),
      if (s.toolCount > 0) MapEntry('工具个数', '${s.toolCount}'),
      MapEntry('是否内置', s.builtin ? '是' : '否'),
      MapEntry('标识', s.id),
      if (s.description.isNotEmpty) MapEntry('说明', s.description),
    ];
  }

  static List<MapEntry<String, String>> _skillDetails(SkillOption k) {
    return [
      if (k.description.isNotEmpty) MapEntry('说明', k.description),
      if (k.context.isNotEmpty) MapEntry('上下文', k.context),
      if (k.allowedTools.isNotEmpty) MapEntry('可用工具', k.allowedTools.join('、')),
      MapEntry('可手动调用', k.userInvocable ? '是' : '否'),
      MapEntry('状态', k.disabled ? '已停用' : '已启用'),
      MapEntry('标识', k.id),
    ];
  }
}

class _VersionCard extends StatelessWidget {
  final Capabilities caps;
  const _VersionCard({required this.caps});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.desktop_windows_outlined, color: Colors.lightBlueAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('电脑端已连接',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    '互通版本 ${caps.desktopVersion.isEmpty ? "未知" : caps.desktopVersion}'
                    '${caps.upstreamVersion.isEmpty ? "" : "  ·  主程序 ${caps.upstreamVersion}"}',
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final int count;
  final List<Widget> children;

  const _Section({
    required this.icon,
    required this.title,
    required this.hint,
    required this.count,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Row(
              children: [
                Icon(icon, size: 17, color: Colors.lightBlueAccent),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$count',
                      style: const TextStyle(fontSize: 11, color: Colors.white70)),
                ),
                const Spacer(),
                Flexible(
                  child: Text(hint,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white30)),
                ),
              ],
            ),
          ),
          if (children.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text('（空）', style: TextStyle(fontSize: 12, color: Colors.white30)),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<MapEntry<String, String>>? details;

  const _Row({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.details,
  });

  @override
  Widget build(BuildContext context) {
    final hasDetails = details != null && details!.isNotEmpty;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 17, color: Colors.white38),
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle,
              style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
      trailing: hasDetails
          ? const Icon(Icons.chevron_right, size: 17, color: Colors.white24)
          : null,
      // 有详情才能点进去 —— 点开是一个纯展示的弹层
      onTap: hasDetails ? () => _showDetails(context, title, details!) : null,
    );
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
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
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
