import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';

/// 独立页面（从「设置 → 已连接设备」进入）。
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => state.client.send(Envelope(type: MsgType.presence)),
          ),
        ],
      ),
      body: const DevicesScreen(),
    );
  }
}

/// 设备列表（可单独嵌入）。
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  void _refresh(AppState state) {
    state.client.send(Envelope(type: MsgType.presence));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final peers = state.peers;

    return RefreshIndicator(
      onRefresh: () async => _refresh(state),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SelfCard(state: state),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('在线设备', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Chip(label: Text('${peers.length}'), visualDensity: VisualDensity.compact),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _refresh(state),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  '暂无其他在线设备\n请确保电脑端已通过中继连接',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            )
          else
            ...peers.map(
              (d) => Card(
                color: const Color(0xFF1B1F2B),
                child: ListTile(
                  leading: Icon(
                    d.isDesktop ? Icons.desktop_windows : Icons.phone_android,
                    color: d.isDesktop ? Colors.lightBlueAccent : Colors.greenAccent,
                  ),
                  title: Text(d.deviceName),
                  subtitle: Text(
                      '${d.platform} · ${d.deviceId.length >= 8 ? d.deviceId.substring(0, 8) : d.deviceId}'),
                  trailing: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 8, color: Colors.greenAccent),
                      SizedBox(width: 4),
                      Text('在线', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SelfCard extends StatelessWidget {
  final AppState state;
  const _SelfCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1B1F2B),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本机', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _row('名称', state.config.deviceName),
            _row('设备ID',
                state.config.deviceId.length >= 12
                    ? state.config.deviceId.substring(0, 12)
                    : state.config.deviceId),
            _row('用户', state.config.userId),
            _row('服务器', state.config.serverUrl),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 72, child: Text(k, style: const TextStyle(color: Colors.white54))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
