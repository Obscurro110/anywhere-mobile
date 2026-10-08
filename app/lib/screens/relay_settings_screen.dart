import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_config.dart';
import '../services/app_state.dart';

/// 中继服务器与账号设置（子页面）。
///
/// 从设置页拆出来，避免一堆输入框把设置首页撑得很长。
class RelaySettingsScreen extends StatefulWidget {
  const RelaySettingsScreen({super.key});

  @override
  State<RelaySettingsScreen> createState() => _RelaySettingsScreenState();
}

class _RelaySettingsScreenState extends State<RelaySettingsScreen> {
  // ⚠️ 不用 late：一旦 initState 里 context.read<AppState>() 抛异常，
  // 这四个字段就停留在「未初始化」，而 dispose() 里的 _server.dispose()
  // 会抛 LateInitializationError —— 在 dispose 阶段抛异常会让框架报错。
  // 直接给默认实例，永远可安全 dispose。
  final TextEditingController _server = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _userId = TextEditingController();
  final TextEditingController _deviceName = TextEditingController();
  bool _showToken = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<AppState>().config;
    _server.text = c.serverUrl;
    _token.text = c.token;
    _userId.text = c.userId;
    _deviceName.text = c.deviceName;
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
    final missing = <String>[];
    if (_server.text.trim().isEmpty) missing.add('服务器地址');
    if (_token.text.trim().isEmpty) missing.add('访问令牌');
    if (_userId.text.trim().isEmpty) missing.add('用户 ID');
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请填写：${missing.join('、')}')),
      );
      return;
    }

    final next = AppConfig(
      userId: _userId.text.trim(),
      token: _token.text.trim(),
      serverUrl: _server.text.trim(),
      deviceId: state.config.deviceId,
      deviceName: _deviceName.text.trim(),
    );
    await state.updateConfig(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存并重新连接')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connected = state.client.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('中继服务器'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          // 当前状态
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1F2B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                    size: 20,
                    color: connected ? Colors.greenAccent : Colors.redAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(connected ? '已连接中继' : '未连接',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        '本机 ID：${state.config.deviceId}',
                        style: const TextStyle(fontSize: 11, color: Colors.white38),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '重新连接',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => context.read<AppState>().reconnect(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          const Padding(
            padding: EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              '手机与电脑端必须填写**完全相同**的服务器地址、令牌和用户 ID，否则互相看不到。',
              style: TextStyle(fontSize: 12, color: Colors.white38, height: 1.5),
            ),
          ),

          _field('中继服务器地址', _server, hint: 'wss://your-domain/ws'),
          _field('用户 ID', _userId, hint: 'default-user'),
          _deviceNameRow(),
          _tokenField(),

          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('保存并重连'),
          ),
        ],
      ),
    );
  }

  /// 设备名：默认自动取手机型号，不用用户填。
  /// 只读展示，旁边给一个「重命名」入口，想改的人才改。
  Widget _deviceNameRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: '本机名称',
                helperText: '自动取自手机型号，电脑端设备列表里显示这个名字',
                helperStyle: const TextStyle(fontSize: 11, color: Colors.white38),
                border: const OutlineInputBorder(),
                suffixIcon: _deviceName.text.trim().isEmpty
                    ? null
                    : IconButton(
                        tooltip: '重新探测',
                        icon: const Icon(Icons.autorenew, size: 18),
                        onPressed: _detectName,
                      ),
              ),
              child: Text(
                _deviceName.text.trim().isEmpty ? '检测中…' : _deviceName.text.trim(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '重命名',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _renameName,
          ),
        ],
      ),
    );
  }

  /// 重新探测一次手机型号名
  Future<void> _detectName() async {
    final name = await AppConfig.detectDeviceName();
    if (!mounted) return;
    setState(() => _deviceName.text = name);
  }

  /// 手动改名的弹窗
  Future<void> _renameName() async {
    final ctrl = TextEditingController(text: _deviceName.text);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名本机'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：我的手机',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _deviceName.text = name);
    // 立刻保存，免得用户忘了点「保存并重连」
    final state = context.read<AppState>();
    state.setDeviceName(name);
  }

  Widget _field(String label, TextEditingController c, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
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

  Widget _tokenField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _token,
        obscureText: !_showToken,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: '访问令牌 (Token)',
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF1B1F2B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            icon: Icon(
              _showToken ? Icons.visibility_off : Icons.visibility,
              size: 18,
            ),
            onPressed: () => setState(() => _showToken = !_showToken),
          ),
        ),
      ),
    );
  }
}
