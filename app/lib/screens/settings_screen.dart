import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../services/app_state.dart';
import '../widgets/update_card.dart';
import 'devices_screen.dart';
import 'tasks_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _server;
  late TextEditingController _token;
  late TextEditingController _userId;
  late TextEditingController _deviceName;

  @override
  void initState() {
    super.initState();
    final c = context.read<AppState>().config;
    _server = TextEditingController(text: c.serverUrl);
    _token = TextEditingController(text: c.token);
    _userId = TextEditingController(text: c.userId);
    _deviceName = TextEditingController(text: c.deviceName);
  }

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    _userId.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final next = AppConfig(
      userId: _userId.text.trim(),
      token: _token.text.trim(),
      serverUrl: _server.text.trim(),
      deviceId: state.config.deviceId,
      deviceName: _deviceName.text.trim(),
    );
    await state.updateConfig(next);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存并重新连接')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final caps = state.capabilities;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---------- 设备 ----------
        const Text('设备', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Card(
          color: const Color(0xFF1B1F2B),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.devices, color: Colors.lightBlueAccent),
                title: const Text('已连接设备'),
                subtitle: Text(state.peers.isEmpty
                    ? '暂无其他在线设备'
                    : '${state.peers.length} 台在线 · ${state.peers.map((d) => d.deviceName).join('、')}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesPage()),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.schedule, color: Colors.amberAccent),
                title: const Text('定时任务'),
                subtitle: Text(state.tasks.isEmpty
                    ? '点此同步电脑端的定时任务'
                    : '${state.tasks.length} 个任务 · 可「立即运行」'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TasksPage()),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  caps.isEmpty ? Icons.cloud_off : Icons.cloud_done,
                  color: caps.isEmpty ? Colors.white38 : Colors.greenAccent,
                ),
                title: const Text('电脑端能力'),
                subtitle: Text(caps.isEmpty
                    ? '未获取到（点右侧刷新）'
                    : '助手 ${caps.prompts.length} · 模型 ${caps.models.length} · MCP ${caps.mcp.length} · Skill ${caps.skills.length}'),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: state.requestCapabilities,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 40),

        // ---------- 连接设置 ----------
        const Text('连接设置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 12),
        _field('中继服务器地址', _server, hint: 'wss://your-domain/ws'),
        _field('访问令牌 (Token)', _token, obscure: true),
        _field('用户 ID', _userId),
        _field('本机名称', _deviceName),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save),
          label: const Text('保存并重连'),
        ),
        const Divider(height: 40),

        // ---------- 关于 / 更新 ----------
        const Text('关于', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        const UpdateCard(),
        const Divider(height: 40),

        // ---------- 数据 ----------
        const Text('数据', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            await state.clearHistory();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('聊天记录已清空')),
              );
            }
          },
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('清空聊天记录'),
        ),
        const SizedBox(height: 24),
        const Text(
          'Anywhere Mobile · 与电脑版 Anywhere Desktop 通过公网中继互通\n'
          '支持对话（含模型 / 思考预算 / MCP / Skill / 会话压缩）、文件互传与通知推送',
          style: TextStyle(color: Colors.white38, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '设备ID: ${state.config.deviceId.length >= 12 ? state.config.deviceId.substring(0, 12) : state.config.deviceId}',
            style: const TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, {String? hint, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: c,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: const Color(0xFF1B1F2B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
