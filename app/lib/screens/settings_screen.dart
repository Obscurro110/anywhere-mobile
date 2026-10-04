import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/setting_tiles.dart';
import '../widgets/update_card.dart';
import 'conversations_screen.dart';
import 'desktop_capabilities_screen.dart';
import 'devices_screen.dart';
import 'relay_settings_screen.dart';

/// 设置页（二级页面，从右上角 ⋮ 进入）。
///
/// 排版原则：
///  - 顶部一张「状态卡」一眼看清连接情况
///  - 下面按用途分组的卡片，每组只放 2~4 条
///  - 长表单（中继参数）收进子页面，不在这里展开
///  - 底部才放「关于 / 更新」这类低频内容
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          _StatusCard(state: state),
          const SizedBox(height: 18),

          // ---------- 与电脑端 ----------
          const SettingGroupTitle('与电脑端'),
          SettingCard(children: [
            SettingTile(
              icon: Icons.forum_outlined,
              iconColor: Colors.lightBlueAccent,
              title: '电脑端对话',
              value: state.activeConversationId != null
                  ? '对话中'
                  : (state.conversations.isEmpty
                      ? '未同步'
                      : '${state.conversations.length} 个'),
              subtitle: state.activeConversationId != null
                  ? (state.activeConversationTitle.isEmpty
                      ? '点此切换或退出'
                      : state.activeConversationTitle)
                  : '列出电脑端已有会话，点开即可接着聊',
              onTap: () => _push(context, const ConversationsPage()),
            ),
            SettingTile(
              icon: Icons.devices,
              iconColor: Colors.lightBlueAccent,
              title: '设备',
              value: state.peers.isEmpty
                  ? '暂无在线'
                  : '${state.peers.length} 台在线',
              subtitle: state.peers.isEmpty
                  ? null
                  : state.peers.map((d) => d.deviceName).join('、'),
              onTap: () => _push(context, const DevicesPage()),
            ),
            // 电脑端能力的四类，各自一个入口（点进去只显示这一类）
            ...CapabilityKind.values.map((k) {
              final caps = state.capabilities;
              final n = switch (k) {
                CapabilityKind.prompts => caps.prompts.length,
                CapabilityKind.models => caps.models.length,
                CapabilityKind.mcp => caps.mcp.length,
                CapabilityKind.skills => caps.skills.length,
              };
              return SettingTile(
                icon: k.icon,
                iconColor: caps.isEmpty
                    ? Colors.white38
                    : (n > 0 ? Colors.greenAccent : Colors.white38),
                title: k.title,
                value: caps.isEmpty ? '未获取' : k.countText(caps),
                subtitle: caps.isEmpty ? '点此从电脑端拉取' : k.summary(caps),
                onTap: () => _push(context, DesktopCapabilityPage(kind: k)),
              );
            }),
          ]),

          // ---------- 连接 ----------
          const SettingGroupTitle('连接'),
          SettingCard(children: [
            SettingTile(
              icon: Icons.dns_outlined,
              title: '中继服务器与账号',
              value: _shortHost(state.config.serverUrl),
              subtitle: '服务器地址 / 令牌 / 用户 ID',
              onTap: () => _push(context, const RelaySettingsScreen()),
            ),
          ]),

          // ---------- 数据 ----------
          const SettingGroupTitle('本机数据'),
          SettingCard(children: [
            SettingTile(
              icon: Icons.cleaning_services_outlined,
              title: '清空本机聊天记录',
              subtitle: '仅清空这台手机上的显示缓存；电脑端的会话不受影响',
              onTap: () => _confirmClear(context, state),
            ),
          ]),

          // ---------- 关于 ----------
          const SettingGroupTitle('关于'),
          const UpdateCard(),

          const SizedBox(height: 22),
          const _Footer(),
        ],
      ),
    );
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  static String _shortHost(String url) {
    if (url.isEmpty) return '未配置';
    final m = RegExp(r'^(wss?|https?)://([^/:]+)').firstMatch(url);
    return m?.group(2) ?? url;
  }

  static Future<void> _confirmClear(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空本机聊天记录'),
        content: const Text(
          '仅清空这台手机上显示的聊天记录。\n\n'
          '电脑端的会话和 AI 的记忆都不受影响——'
          '下次发消息时，电脑端仍会带着完整上下文回答。\n\n'
          '如需真正删除某个会话，请到「电脑端对话」里操作。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await state.clearHistory();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已清空本机记录')));
    }
  }
}

/// 顶部状态卡：连接状态 + 当前设备 + 版本，一屏看完关键信息。
class _StatusCard extends StatelessWidget {
  final AppState state;
  const _StatusCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final connected = state.client.isConnected;
    final version = state.appVersion;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? const [Color(0xFF1D2A3A), Color(0xFF1A1F2E)]
              : const [Color(0xFF2A1F1F), Color(0xFF1A1F2E)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: connected ? const Color(0xFF2E5A7A) : const Color(0xFF5A2E2E),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.cloud_done : Icons.cloud_off,
                size: 20,
                color: connected ? Colors.greenAccent : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Text(
                connected ? '已连接中继' : '未连接',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0x40000000),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('v$version',
                    style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _kv('本机', '${state.config.deviceName} · ${_short(state.config.deviceId)}'),
          if (state.capabilities.desktopVersion.isNotEmpty)
            _kv('电脑端', 'v${state.capabilities.desktopVersion}'),
          if (state.peers.isNotEmpty)
            _kv('在线设备', state.peers.map((d) => d.deviceName).join('、')),
        ],
      ),
    );
  }

  static String _short(String id) =>
      id.length >= 10 ? id.substring(0, 10) : id;

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              child: Text(k,
                  style: const TextStyle(fontSize: 12, color: Colors.white38)),
            ),
            Expanded(
              child: Text(v, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
          ],
        ),
      );
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Text(
          'Anywhere Mobile',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        SizedBox(height: 4),
        Text(
          '与电脑版 Anywhere Desktop 通过公网中继互通',
          style: TextStyle(color: Colors.white24, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
