import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 定时任务：展示电脑端配置的所有定时任务，可「立即运行」。
///
/// 只能查看与触发 —— 新建/编辑仍然在电脑端做（保持单一数据源）。
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().requestTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tasks = state.tasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('定时任务'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => state.requestTasks(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => state.requestTasks(),
        child: _body(context, state, tasks),
      ),
    );
  }

  Widget _body(BuildContext context, AppState state, List<TaskOption> tasks) {
    if (state.loadingTasks && tasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tasks.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 60),
          Icon(Icons.schedule_outlined, size: 56, color: Colors.white24),
          SizedBox(height: 14),
          Text('暂无定时任务',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54)),
          SizedBox(height: 6),
          Text('在电脑端「定时任务」里新建，这里会同步显示，并可随时「立即运行」',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    final last = state.lastTaskRun;

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: tasks.length + (last == null ? 0 : 1),
      itemBuilder: (context, i) {
        if (last != null && i == 0) {
          final ok = last['ok'] == true;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              color: ok ? const Color(0xFF1B2B1F) : const Color(0xFF2B1B1B),
              child: ListTile(
                dense: true,
                leading: Icon(ok ? Icons.check_circle : Icons.error_outline,
                    color: ok ? Colors.greenAccent : Colors.redAccent),
                title: Text(ok ? '任务已触发' : '任务未能运行'),
                subtitle: Text(
                  ok
                      ? '电脑端已开始执行'
                      : (last['reason']?.toString() ?? '未知原因'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: state.clearTaskRun,
                ),
              ),
            ),
          );
        }

        final t = tasks[last == null ? i : i - 1];
        return Card(
          color: const Color(0xFF1B1F2B),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              t.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: t.enabled
                                  ? const Color(0xFF23401F)
                                  : const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              t.enabled ? '本机已启用' : '本机未启用',
                              style: TextStyle(
                                fontSize: 10,
                                color: t.enabled ? Colors.greenAccent : Colors.white38,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.alarm, size: 13, color: Colors.white38),
                          const SizedBox(width: 4),
                          Text(t.schedule,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white54)),
                          if (t.promptKey.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            const Icon(Icons.auto_awesome,
                                size: 13, color: Colors.white38),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(t.promptKey,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.white54)),
                            ),
                          ],
                        ],
                      ),
                      if (t.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          t.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white38),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: '立即运行',
                  onPressed: () => _run(context, state, t),
                  icon: const Icon(Icons.play_arrow),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _run(BuildContext context, AppState state, TaskOption t) async {
    if (!state.client.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接到中继服务器')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('立即运行'),
        content: Text('让电脑端马上执行「${t.label}」？\n\n'
            '将在电脑端新开一个会话执行该任务。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('运行')),
        ],
      ),
    );
    if (ok != true) return;
    final sent = state.runTask(t.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(sent ? '已请求电脑端运行…' : '发送失败')),
      );
    }
  }
}
