import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 定时任务：查看 / 新建 / 改名 / 启停 / 改调度 / 立即运行 / 清空历史 / 删除。
///
/// 数据源仍是电脑端的 config.tasks（单一数据源），手机这边只是远程操作它，
/// 和电脑端 Tasks.vue 的 atomicSave 落的是同一份配置。
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, state),
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
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
          Text('还没有定时任务',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54)),
          SizedBox(height: 6),
          Text('点右下角「新建任务」，或到电脑端创建',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    final last = state.lastTaskRun;
    final action = state.lastTaskAction;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      itemCount: tasks.length + (last == null ? 0 : 1) + (action == null ? 0 : 1),
      itemBuilder: (context, i) {
        var idx = i;

        if (action != null && idx == 0) {
          return _resultCard(
            ok: action['ok'] == true,
            title: action['ok'] == true ? _opDone(action['op'] as String? ?? '') : '操作失败',
            subtitle: _opReason(action),
            onClose: state.clearTaskAction,
          );
        }
        if (action != null) idx -= 1;

        if (last != null && idx == 0) {
          final ok = last['ok'] == true;
          return _resultCard(
            ok: ok,
            title: ok ? '任务已触发' : '任务未能运行',
            subtitle: ok ? '电脑端已开始执行' : (last['reason']?.toString() ?? '未知原因'),
            onClose: state.clearTaskRun,
          );
        }
        if (last != null) idx -= 1;

        final t = tasks[idx];
        return _taskCard(context, state, t);
      },
    );
  }

  String _opDone(String op) {
    switch (op) {
      case 'create':
        return '已新建任务';
      case 'delete':
        return '已删除任务';
      case 'update':
        return '已保存修改';
      case 'setEnabled':
        return '已切换启用状态';
      case 'clearHistory':
        return '已清空历史记录';
      default:
        return '操作完成';
    }
  }

  String _opReason(Map<String, dynamic> a) {
    final r = a['reason']?.toString() ?? '';
    const map = {
      'name_required': '任务名不能为空',
      'name_invalid_char': '任务名不能包含 \\ / : * ? " < > |',
      'task_not_found': '电脑端找不到这个任务（可能已被删除）',
      'taskId_required': '缺少任务 ID',
      'config_api_unavailable': '电脑端配置接口不可用',
    };
    if (map.containsKey(r)) return map[r]!;
    return r.isEmpty ? '电脑端未说明原因' : r;
  }

  Widget _resultCard({
    required bool ok,
    required String title,
    required String subtitle,
    required VoidCallback onClose,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: ok ? const Color(0xFF1B2B1F) : const Color(0xFF2B1B1B),
        child: ListTile(
          dense: true,
          leading: Icon(ok ? Icons.check_circle : Icons.error_outline,
              color: ok ? Colors.greenAccent : Colors.redAccent),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
          ),
        ),
      ),
    );
  }

  Widget _taskCard(BuildContext context, AppState state, TaskOption t) {
    return Card(
      color: const Color(0xFF1B1F2B),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
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
                      Flexible(
                        child: Text(t.schedule,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white54)),
                      ),
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
            IconButton.filledTonal(
              tooltip: '立即运行',
              onPressed: () => _run(context, state, t),
              icon: const Icon(Icons.play_arrow),
            ),
            IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert, color: Colors.white54),
              onPressed: () => _menu(context, state, t),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 操作菜单

  Future<void> _menu(BuildContext context, AppState state, TaskOption t) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(t.label,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                t.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
                color: Colors.lightBlueAccent,
              ),
              title: Text(t.enabled ? '停用（本机）' : '启用（本机）'),
              subtitle: const Text('控制是否在这台电脑上按计划运行',
                  style: TextStyle(fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule),
              title: const Text('修改调度'),
              subtitle: Text(t.schedule, style: const TextStyle(fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'schedule'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('换助手 / 改说明'),
              onTap: () => Navigator.pop(ctx, 'prompt'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清空历史记录'),
              subtitle: Text('现有 ${t.historyCount} 条',
                  style: const TextStyle(fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'clearHistory'),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除任务', style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'toggle':
        state.setTaskEnabled(t.id, !t.enabled);
      case 'rename':
        await _rename(context, state, t);
      case 'schedule':
        await _editSchedule(context, state, t);
      case 'prompt':
        await _editAssistant(context, state, t);
      case 'clearHistory':
        await _clearHistory(context, state, t);
      case 'delete':
        await _delete(context, state, t);
    }
  }

  Future<void> _create(BuildContext context, AppState state) async {
    final name = await _askName(context, title: '新建定时任务');
    if (name == null || !context.mounted) return;
    final sent = state.createTask(name);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sent ? '已新建「$name」' : '发送失败（名称可能含非法字符）'),
      ));
    }
  }

  Future<void> _rename(
      BuildContext context, AppState state, TaskOption t) async {
    final name = await _askName(context, title: '重命名任务', initial: t.label);
    if (name == null || !context.mounted) return;
    final sent = state.renameTask(t.id, name);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sent ? '已重命名' : '发送失败（名称可能含非法字符）'),
      ));
    }
  }

  Future<void> _clearHistory(
      BuildContext context, AppState state, TaskOption t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史记录'),
        content: Text('将清空「${t.label}」的 ${t.historyCount} 条运行记录。\n\n'
            '只清记录，不会删除电脑上的会话内容。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    state.clearTaskHistory(t.id);
  }

  Future<void> _delete(
      BuildContext context, AppState state, TaskOption t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('将把「${t.label}」从电脑端配置里删除。\n\n此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    state.deleteTask(t.id);
  }

  Future<String?> _askName(BuildContext context,
      {required String title, String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如：每天早上总结新闻',
            helperText: '不能包含 \\ / : * ? " < > |',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (res == null || res.isEmpty) return null;
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(res)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('名称不能包含 \\ / : * ? " < > |')),
        );
      }
      return null;
    }
    return res;
  }

  // ------------------------------------------------------------ 改调度（简化版）

  Future<void> _editSchedule(
      BuildContext context, AppState state, TaskOption t) async {
    var type = t.triggerType.isEmpty ? 'interval' : t.triggerType;
    final intervalCtrl =
        TextEditingController(text: t.intervalMinutes.toString());
    final dailyCtrl = TextEditingController(text: t.dailyTime);
    final descCtrl = TextEditingController(text: t.description);

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('修改调度'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 用 Wrap + ChoiceChip 而不是 DropdownButtonFormField：
                // 后者在 Flutter 3.35 把 value 改名成了 initialValue，
                // 两边都传会有 deprecation/编译风险，这里直接绕开。
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('触发方式', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <(String, String)>[
                    ('interval', '每隔一段时间'),
                    ('daily', '每天固定时刻'),
                    ('weekly', '每周'),
                    ('monthly', '每月'),
                    ('single', '仅一次'),
                  ]
                      .map((e) => ChoiceChip(
                            label: Text(e.$2, style: const TextStyle(fontSize: 12)),
                            selected: type == e.$1,
                            onSelected: (_) => setLocal(() => type = e.$1),
                          ))
                      .toList(),
                ),
                if (type == 'interval') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: intervalCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: '间隔（分钟）', hintText: '60'),
                  ),
                ],
                if (type == 'daily' ||
                    type == 'weekly' ||
                    type == 'monthly') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: dailyCtrl,
                    decoration:
                        const InputDecoration(labelText: '时刻', hintText: '12:00'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                      labelText: '说明（可选）', hintText: '这个任务是干什么的'),
                ),
                const SizedBox(height: 8),
                const Text(
                  '提示：更复杂的调度（每周几 / 每月几号 / 时间段）建议在电脑端设置。',
                  style: TextStyle(fontSize: 11, color: Colors.white38, height: 1.4),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );

    if (save != true) {
      intervalCtrl.dispose();
      dailyCtrl.dispose();
      descCtrl.dispose();
      return;
    }

    final patch = <String, dynamic>{
      'triggerType': type,
      'description': descCtrl.text.trim(),
    };
    if (type == 'interval') {
      final m = int.tryParse(intervalCtrl.text.trim());
      if (m != null && m > 0) patch['intervalMinutes'] = m;
    }
    if (type == 'daily') patch['dailyTime'] = dailyCtrl.text.trim();
    if (type == 'weekly') patch['weeklyTime'] = dailyCtrl.text.trim();
    if (type == 'monthly') patch['monthlyTime'] = dailyCtrl.text.trim();

    intervalCtrl.dispose();
    dailyCtrl.dispose();
    descCtrl.dispose();

    if (!context.mounted) return;
    state.updateTaskSchedule(t.id, patch);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存调度（电脑端刷新后生效）')),
    );
  }

  // ------------------------------------------------------------ 换助手

  Future<void> _editAssistant(
      BuildContext context, AppState state, TaskOption t) async {
    final prompts = state.capabilities.prompts;
    if (prompts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('电脑端还没上报助手列表，请先点刷新'),
      ));
      return;
    }
    final descCtrl = TextEditingController(text: t.description);

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('任务使用的助手',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: descCtrl,
                decoration: const InputDecoration(
                    labelText: '说明（可选）', isDense: true),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    dense: true,
                    title: const Text('跟随电脑端默认（__DEFAULT__）'),
                    trailing: t.promptKey == '__DEFAULT__'
                        ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                        : null,
                    onTap: () => Navigator.pop(ctx, '__DEFAULT__'),
                  ),
                  ...prompts.map((p) => ListTile(
                        dense: true,
                        title: Text(p.label),
                        subtitle: Text(
                          p.hasPreset ? '预设：${p.presetSummary}' : '无预设',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: t.promptKey == p.key
                            ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                            : null,
                        onTap: () => Navigator.pop(ctx, p.key),
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (picked == null || !context.mounted) {
      descCtrl.dispose();
      return;
    }
    final desc = descCtrl.text.trim();
    descCtrl.dispose();

    state.updateTaskSchedule(t.id, {
      'promptKey': picked,
      'description': desc,
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存（电脑端刷新后生效）')),
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
