import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';

/// 定时任务编辑页，字段和电脑端 Tasks.vue 对齐：
/// 触发规则、执行内容、后台行为。
class TaskEditorPage extends StatefulWidget {
  final TaskOption task;
  const TaskEditorPage({super.key, required this.task});

  @override
  State<TaskEditorPage> createState() => _TaskEditorPageState();
}

class _TaskEditorPageState extends State<TaskEditorPage> {
  static const _routes = [
    ('superior', '强思维模型'),
    ('general', '通用模型'),
    ('fast', '快速模型'),
  ];
  static const _week = [1, 2, 3, 4, 5, 6, 0];
  static const _weekName = {
    1: '周一',
    2: '周二',
    3: '周三',
    4: '周四',
    5: '周五',
    6: '周六',
    0: '周日',
  };

  late String _type;
  late int _minutes;
  late String _intervalStart;
  late List<List<String>> _ranges;
  late String _daily;
  late List<int> _weeklyDays;
  late String _weeklyTime;
  late List<int> _monthlyDays;
  late String _monthlyTime;
  late String _singleDate;
  late String _singleTime;
  late String _promptKey;
  late String _modelRoute;
  late TextEditingController _prompt;
  late List<String> _mcp;
  late List<String> _skills;
  late bool _autoSave;
  late String _projectId;
  late bool _autoClose;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _type = t.triggerType.isEmpty ? 'interval' : t.triggerType;
    _minutes = t.intervalMinutes < 1 ? 60 : t.intervalMinutes;
    _intervalStart = t.intervalStartTime;
    _ranges = t.intervalTimeRanges.map((e) => [...e]).toList();
    _daily = t.dailyTime;
    _weeklyDays = [...t.weeklyDays];
    _weeklyTime = t.weeklyTime;
    _monthlyDays = [...t.monthlyDays];
    _monthlyTime = t.monthlyTime;
    _singleDate = t.singleDate;
    _singleTime = t.singleTime;
    _promptKey = t.promptKey.isEmpty ? '__DEFAULT__' : t.promptKey;
    _modelRoute = t.modelRoute.isEmpty ? 'general' : t.modelRoute;
    _prompt = TextEditingController(text: t.description);
    _mcp = [...t.extraMcp];
    _skills = [...t.extraSkills];
    _autoSave = t.autoSave;
    _projectId = t.autoSaveProjectId;
    _autoClose = t.autoClose;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task.label),
        actions: [
          TextButton(onPressed: () => _save(state), child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _title('触发规则'),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: const [
              ('single', '单次执行'),
              ('interval', '间隔触发'),
              ('daily', '每日定时'),
              ('weekly', '每周定时'),
              ('monthly', '每月定时'),
            ]
                .map((e) => ChoiceChip(
                      label: Text(e.$2),
                      selected: _type == e.$1,
                      onSelected: (_) => setState(() => _type = e.$1),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          ..._triggerFields(),
          const SizedBox(height: 18),
          _title('执行内容与目标'),
          const SizedBox(height: 4),
          const Text('选择目标快捷助手',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('默认助手'),
                selected: _promptKey == '__DEFAULT__',
                onSelected: (_) => setState(() => _promptKey = '__DEFAULT__'),
              ),
              ...state.capabilities.prompts.map((p) => ChoiceChip(
                    label: Text(p.label),
                    selected: _promptKey == p.key,
                    onSelected: (_) => setState(() => _promptKey = p.key),
                  )),
            ],
          ),
          if (_promptKey == '__DEFAULT__') ...[
            const SizedBox(height: 12),
            const Text('默认助手模型能力',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: _routes
                  .map((e) => ChoiceChip(
                        label: Text(e.$2),
                        selected: _modelRoute == e.$1,
                        onSelected: (_) => setState(() => _modelRoute = e.$1),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '自动发送的指令内容 (Prompt)',
              alignLabelWithHint: true,
              hintText: '用自然语言描述 AI 要做什么',
            ),
          ),
          const SizedBox(height: 18),
          _title('后台行为与扩展能力'),
          const SizedBox(height: 8),
          _multi(
            '临时覆盖的 MCP 服务',
            state.capabilities.mcp.map((m) => (m.id, m.label)).toList(),
            _mcp,
          ),
          const SizedBox(height: 8),
          _multi(
            '临时覆盖的 Skill 技能',
            state.capabilities.skills.map((s) => (s.id, s.label)).toList(),
            _skills,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动保存对话记录'),
            subtitle: const Text('保存为「任务名-时间」'),
            value: _autoSave,
            onChanged: (v) => setState(() => _autoSave = v),
          ),
          if (_autoSave)
            DropdownButtonFormField<String>(
              initialValue: state.taskProjects.any((p) => p['id'] == _projectId)
                  ? _projectId
                  : '',
              decoration: const InputDecoration(labelText: '保存到'),
              items: [
                const DropdownMenuItem(value: '', child: Text('未分组')),
                ...state.taskProjects.map((p) => DropdownMenuItem(
                      value: p['id'],
                      child: Text(p['name'] ?? p['id']!),
                    )),
              ],
              onChanged: (v) => setState(() => _projectId = v ?? ''),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('AI 执行完毕后自动关闭窗口'),
            value: _autoClose,
            onChanged: (v) => setState(() => _autoClose = v),
          ),
        ],
      ),
    );
  }

  List<Widget> _triggerFields() {
    switch (_type) {
      case 'single':
        return [
          _timeRow('执行日期', _singleDate.isEmpty ? '选择日期' : _singleDate, _pickDate),
          _timeRow('执行时间', _singleTime, () => _pickTime(_singleTime, (v) => _singleTime = v)),
        ];
      case 'daily':
        return [
          _timeRow('每日触发时间', _daily, () => _pickTime(_daily, (v) => _daily = v)),
        ];
      case 'weekly':
        return [
          Wrap(
            spacing: 6,
            children: _week
                .map((d) => FilterChip(
                      label: Text(_weekName[d]!),
                      selected: _weeklyDays.contains(d),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _weeklyDays.add(d);
                        } else {
                          _weeklyDays.remove(d);
                        }
                      }),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          _timeRow('触发时间', _weeklyTime, () => _pickTime(_weeklyTime, (v) => _weeklyTime = v)),
        ];
      case 'monthly':
        return [
          const Text('每月几号执行', style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: List.generate(31, (i) {
              final day = i + 1;
              return FilterChip(
                label: Text('$day'),
                visualDensity: VisualDensity.compact,
                selected: _monthlyDays.contains(day),
                onSelected: (on) => setState(() {
                  if (on) {
                    _monthlyDays.add(day);
                  } else {
                    _monthlyDays.remove(day);
                  }
                }),
              );
            }),
          ),
          const SizedBox(height: 8),
          _timeRow('触发时间', _monthlyTime, () => _pickTime(_monthlyTime, (v) => _monthlyTime = v)),
        ];
      default:
        return [
          Row(
            children: [
              const Text('间隔时间（分钟）'),
              const Spacer(),
              IconButton(
                onPressed: _minutes > 1 ? () => setState(() => _minutes -= 1) : null,
                icon: const Icon(Icons.remove),
              ),
              Text('$_minutes', style: const TextStyle(fontSize: 16)),
              IconButton(
                onPressed: () => setState(() => _minutes += 1),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          _timeRow(
            '每日起始时间',
            _intervalStart,
            () => _pickTime(_intervalStart, (v) => _intervalStart = v),
          ),
          const SizedBox(height: 8),
          const Text('生效时间段（可选）', style: TextStyle(fontSize: 12, color: Colors.white54)),
          ..._ranges.asMap().entries.map((e) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${e.value[0]} 至 ${e.value[1]}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _ranges.removeAt(e.key)),
                ),
              )),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addRange,
              icon: const Icon(Icons.add),
              label: const Text('添加时间段'),
            ),
          ),
        ];
    }
  }

  Widget _multi(String title, List<(String, String)> items, List<String> selected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.white54)),
        const SizedBox(height: 6),
        if (items.isEmpty)
          const Text('电脑端还没有可选项，先点任务页的刷新',
              style: TextStyle(fontSize: 12, color: Colors.white38))
        else
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: items
                .map((e) => FilterChip(
                      label: Text(e.$2),
                      selected: selected.contains(e.$1),
                      onSelected: (on) => setState(() {
                        if (on) {
                          selected.add(e.$1);
                        } else {
                          selected.remove(e.$1);
                        }
                      }),
                    ))
                .toList(),
          ),
      ],
    );
  }

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );

  Widget _timeRow(String label, String value, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(value.isEmpty ? '未设置' : value),
      onTap: onTap,
    );
  }

  Future<void> _pickTime(String current, void Function(String) apply) async {
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 12,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final text =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() => apply(text));
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    DateTime initial = now;
    final parsed = DateTime.tryParse(_singleDate);
    if (parsed != null) initial = parsed;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    setState(() {
      _singleDate =
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _addRange() async {
    final start = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (start == null || !mounted) return;
    final end = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 18, minute: 0));
    if (end == null) return;
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() => _ranges.add([fmt(start), fmt(end)]));
  }

  void _save(AppState state) {
    final sent = state.updateTaskSchedule(widget.task.id, {
      'triggerType': _type,
      'intervalMinutes': _minutes,
      'intervalStartTime': _intervalStart,
      'intervalTimeRanges': _ranges,
      'dailyTime': _daily,
      'weeklyDays': _weeklyDays,
      'weeklyTime': _weeklyTime,
      'monthlyDays': _monthlyDays,
      'monthlyTime': _monthlyTime,
      'singleDate': _singleDate,
      'singleTime': _singleTime,
      'promptKey': _promptKey,
      'modelRoute': _modelRoute,
      'description': _prompt.text,
      'extraMcp': _mcp,
      'extraSkills': _skills,
      'autoSave': _autoSave,
      'autoSaveProjectId': _projectId,
      'autoClose': _autoClose,
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(sent ? '已保存' : '发送失败')),
    );
    if (sent) Navigator.pop(context);
  }
}
