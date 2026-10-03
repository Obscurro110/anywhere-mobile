import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/relay_client.dart';

/// Small colored dot reflecting the relay connection status.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, RelayStatus>((s) => s.status);
    final (color, label) = switch (status) {
      RelayStatus.connected => (Colors.greenAccent, '已连接'),
      RelayStatus.connecting => (Colors.orangeAccent, '连接中'),
      RelayStatus.disconnected => (Colors.redAccent, '未连接'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
    );
  }
}
