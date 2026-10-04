import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';
import 'desktop_capabilities_screen.dart' show CapabilityKind;


/// 从模型列表推导服务商（capabilities 只报了打平的 models，
/// 这里按 providerLabel 分组还原出「服务商」视图）。
class _ProviderView {
  final String id; // providerLabel（手机端可见的名字）
  final String name;
  final List<String> models;
  _ProviderView(this.id, this.name, this.models);
}

List<_ProviderView> _groupProviders(Capabilities caps) {
  final order = <String>[];
  final map = <String, List<String>>{};
  for (final m in caps.models) {
    final pid = m.providerLabel;
    if (pid.isEmpty) continue;
    if (!map.containsKey(pid)) {
      map[pid] = [];
      order.add(pid);
    }
    if (!map[pid]!.contains(m.label)) map[pid]!.add(m.label);
  }
  return [
    for (final pid in order) _ProviderView(pid, pid, map[pid]!),
  ];
}


String _kindTitle(CapabilityKind k) => switch (k) {
      CapabilityKind.prompts => '助手',
      CapabilityKind.models => '模型',
      CapabilityKind.mcp => 'MCP 工具',
      CapabilityKind.skills => 'Skill 技能',
    };

/// 电脑端能力的**编辑**页。
///
/// 以前手机上这四类只能看，想改必须到电脑上。现在对齐电脑端设置页：
/// 助手 / 模型(服务商) / MCP / Skill 都能增删改。
class DesktopCapabilityEditPage extends StatefulWidget {
  final CapabilityKind kind;
  /// 要编辑的条目（null = 新建）
  final String? editId;

  const DesktopCapabilityEditPage({super.key, required this.kind, this.editId});

  @override
  State<DesktopCapabilityEditPage> createState() => _DesktopCapabilityEditPageState();
}

class _DesktopCapabilityEditPageState extends State<DesktopCapabilityEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _apiKey; // 只写不读：留空 = 不修改
  late final TextEditingController _prompt;
  late final TextEditingController _command;
  late final TextEditingController _modelsText; // 一行一个模型
  late final TextEditingController _argsText; // 空格分隔参数

  String? _model; // 助手绑定的模型
  String _effort = 'default';
  Set<String> _mcp = {};
  Set<String> _skills = {};
  bool _enable = true;
  String _mcpType = 'stdio';
  bool _busy = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _url = TextEditingController();
    _apiKey = TextEditingController();
    _prompt = TextEditingController();
    _command = TextEditingController();
    _modelsText = TextEditingController();
    _argsText = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _apiKey.dispose();
    _prompt.dispose();
    _command.dispose();
    _modelsText.dispose();
    _argsText.dispose();
    super.dispose();
  }

  /// 把要编辑的条目回填进表单（capabilities 到达后调用一次）
  bool _filled = false;
  void _fillOnce(AppState state) {
    if (_filled) return;
    final caps = state.capabilities;
    final id = widget.editId;
    switch (widget.kind) {
      case CapabilityKind.prompts:
        final p = id == null ? null : caps.prompts.where((e) => e.key == id).firstOrNull;
        _name.text = p?.label ?? '';
        _prompt.text = '';
        _model = (p?.model.isNotEmpty ?? false) ? p!.model : null;
        _effort = (p?.reasoningEffort.isNotEmpty ?? false) ? p!.reasoningEffort : 'default';
        _mcp = p?.mcp.toSet() ?? {};
        _skills = p?.skills.toSet() ?? {};
        _enable = true;
        break;
      case CapabilityKind.models:
        // capabilities 只带「服务商名 + 模型列表」，没有 url/key ——
        // 编辑时这两项留空（电脑端「留空 = 不修改」）。
        final group = _groupProviders(caps).where((g) => g.id == id).firstOrNull;
        _name.text = group?.name ?? '';
        _modelsText.text = (group?.models ?? []).join('\n');
        _enable = true; // capabilities 没报 enable；保存时只有显式改动才传
        break;
      case CapabilityKind.mcp:
        final m = id == null ? null : caps.mcp.where((e) => e.id == id).firstOrNull;
        _name.text = m?.label ?? '';
        _command.text = m?.command ?? '';
        _url.text = m?.url ?? '';
        _mcpType = (m?.type.isNotEmpty ?? false) ? m!.type : 'stdio';
        _argsText.text = '';
        _enable = m?.enabled ?? true;
        break;
      case CapabilityKind.skills:
        final k = id == null ? null : caps.skills.where((e) => e.id == id).firstOrNull;
        _name.text = k?.label ?? '';
        _enable = !(k?.disabled ?? false);
        break;
    }
    _filled = true;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _fillOnce(state);
    final editing = widget.editId != null;
    final title = '${editing ? "编辑" : "新建"}${_kindTitle(widget.kind)}';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
        ],
      ),
      body: state.capabilities.isEmpty
          ? const Center(child: Text('还没拿到电脑端能力', style: TextStyle(color: Colors.white38)))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: _fields(state, editing),
              ),
            ),
    );
  }

  List<Widget> _fields(AppState state, bool editing) {
    final caps = state.capabilities;
    switch (widget.kind) {
      case CapabilityKind.prompts:
        return [
          _field('名称', _name, hint: '助手的显示名'),
          _field('系统提示词', _prompt, max: 8, hint: '留空 = 保持电脑端原值'),
          _pickerTile(
            '模型',
            _model == null ? '默认（跟随电脑端）' : _modelLabelOf(caps, _model),
            onTap: () => _pickModel(state),
          ),
          _pickerTile(
            '思考预算',
            _effort,
            onTap: () => _pickEffort(state),
          ),
          _multiTile(
            'MCP 工具',
            _mcp,
            all: {for (final m in caps.mcp) m.id: (m.label.isEmpty ? m.id : m.label)},
          ),
          _multiTile(
            'Skill 技能',
            _skills,
            all: {for (final k in caps.skills) k.id: (k.label.isEmpty ? k.id : k.label)},
          ),
          SwitchListTile(
            dense: true,
            title: const Text('启用'),
            value: _enable,
            onChanged: (v) => setState(() => _enable = v),
          ),
          if (editing && widget.editId != 'AI') _deleteTile(),
        ];
      case CapabilityKind.models:
        return [
          _field('服务商名称', _name, hint: '如：Doro / Grok / 国模'),
          _field('接口地址', _url, hint: 'https://.../v1'),
          _field('API Key', _apiKey, hint: '留空 = 不修改', secret: true),
          _field('模型列表', _modelsText, max: 10, hint: '每行一个模型名'),
          SwitchListTile(
            dense: true,
            title: const Text('启用'),
            value: _enable,
            onChanged: (v) => setState(() => _enable = v),
          ),
          if (editing) _deleteTile(),
        ];
      case CapabilityKind.mcp:
        final isBuiltin = (widget.editId ?? '').startsWith('builtin_');
        return [
          if (isBuiltin)
            ..._builtinNote()
          else ...[
            _field('标识（id）', TextEditingController(), enabled: false),
            _field('名称', _name),
            _pickerTile('连接方式', _mcpType, onTap: () => _pickMcpType()),
            _field('命令', _command, hint: 'stdio 方式的启动命令'),
            _field('地址', _url, hint: 'sse 方式的 URL'),
            _field('参数', _argsText, hint: '空格分隔'),
          ],
          SwitchListTile(
            dense: true,
            title: const Text('启用'),
            value: _enable,
            onChanged: (v) => setState(() => _enable = v),
          ),
          if (!isBuiltin && editing) _deleteTile(),
        ];
      case CapabilityKind.skills:
        return [
          _infoLine('Skill 是电脑端磁盘上的技能目录，手机端可以启用/停用或删除。'),
          SwitchListTile(
            dense: true,
            title: const Text('允许 AI 调用'),
            subtitle: const Text('关闭后 AI 不再自动使用这个技能'),
            value: _enable,
            onChanged: (v) => setState(() => _enable = v),
          ),
          if (editing) _deleteTile(),
        ];
    }
  }

  bool get isBuiltin => (widget.editId ?? '').startsWith('builtin_');

  List<Widget> _builtinNote() => [
        ListTile(
          dense: true,
          leading: const Icon(Icons.info_outline, size: 18, color: Colors.white38),
          title: Text('内置工具（${widget.editId}）',
              style: const TextStyle(fontSize: 13)),
          subtitle: const Text('内置工具只能启用/停用，不能改参数',
              style: TextStyle(fontSize: 11.5, color: Colors.white54)),
        ),
      ];

  Widget _infoLine(String text) => ListTile(
        dense: true,
        leading: const Icon(Icons.info_outline, size: 18, color: Colors.white38),
        title: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white54)),
      );

  Widget _deleteTile() {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
      title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
      onTap: _busy ? null : _delete,
    );
  }

  String _modelLabelOf(Capabilities caps, String? value) {
    if (value == null || value.isEmpty) return '默认（跟随电脑端）';
    final hit = caps.models.where((m) => m.value == value).firstOrNull;
    return hit?.displayName ?? value;
  }

  Future<void> _pickModel(AppState state) async {
    final caps = state.capabilities;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('选择模型', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ListTile(
                dense: true,
                title: const Text('默认（跟随电脑端）'),
                trailing: _model == null
                    ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                    : null,
                onTap: () => Navigator.pop(ctx, ''),
              ),
              ...caps.models.map((m) => ListTile(
                    dense: true,
                    title: Text(m.displayName),
                    subtitle: Text(m.value, style: const TextStyle(fontSize: 11)),
                    trailing: m.value == _model
                        ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                        : null,
                    onTap: () => Navigator.pop(ctx, m.value),
                  )),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _model = picked.isEmpty ? null : picked);
  }

  Future<void> _pickEffort(AppState state) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: state.capabilities.reasoningEffortOptions
              .map((e) => ListTile(
                    dense: true,
                    title: Text(e),
                    trailing: e == _effort
                        ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                        : null,
                    onTap: () => Navigator.pop(ctx, e),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked != null) setState(() => _effort = picked);
  }

  Future<void> _pickMcpType() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in const ['stdio', 'sse'])
              ListTile(
                dense: true,
                title: Text(t),
                trailing: t == _mcpType
                    ? const Icon(Icons.check, color: Colors.lightBlueAccent)
                    : null,
                onTap: () => Navigator.pop(ctx, t),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _mcpType = picked);
  }

  Widget _multiTile(String label, Set<String> selected,
      {required Map<String, String> all}) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(
        selected.isEmpty ? '（不限）' : selected.map((id) => all[id] ?? id).join('、'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, color: Colors.white54),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
      onTap: () async {
        final result = await showModalBottomSheet<Set<String>>(
          context: context,
          backgroundColor: const Color(0xFF1B1F2B),
          isScrollControlled: true,
          builder: (ctx) => _MultiSelectSheet(all: all, initial: selected),
        );
        if (result != null) setState(() { _mcp = result; });
      },
    );
  }

  Widget _pickerTile(String label, String value, {required VoidCallback onTap}) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(value ?? '', style: const TextStyle(fontSize: 11.5)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
      onTap: onTap,
    );
  }

  Widget _field(String label, TextEditingController c,
      {int max = 1, String? hint, bool secret = false, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: TextFormField(
        controller: c,
        enabled: enabled,
        maxLines: max,
        obscureText: secret,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final caps = state.capabilities;
    final id = widget.editId;

    Map<String, dynamic> body = {};
    String op = '';

    switch (widget.kind) {
      case CapabilityKind.prompts:
        op = 'prompt-save';
        body = {
          'key': id ?? _slug(_name.text),
          'label': _name.text.trim(),
          if (_prompt.text.trim().isNotEmpty) 'prompt': _prompt.text,
          'model': _model ?? '',
          'reasoningEffort': _effort,
          'mcp': _mcp.toList(),
          'skills': _skills.toList(),
          'enable': _enable,
        };
        break;
      case CapabilityKind.models:
        op = 'provider-save';
        body = {
          'id': widget.editId ?? '',
          'name': _name.text.trim(),
          'url': _url.text.trim(),
          'models': _modelsText.text
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          'enable': _enable,
          if (_apiKey.text.trim().isNotEmpty) 'apiKey': _apiKey.text.trim(),
        };
        break;
      case CapabilityKind.mcp:
        op = 'mcp-save';
        body = {
          'id': widget.editId ?? _slug(_name.text),
          'name': _name.text.trim(),
          'type': _mcpType,
          'command': _command.text.trim(),
          'url': _url.text.trim(),
          'args': _argsText.text.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList(),
          'isActive': _enable,
        };
        break;
      case CapabilityKind.skills:
        // Skill 只有开关/删除
        op = 'skill-toggle';
        body = {'id': widget.editId, 'disabled': !_enable};
        break;
    }

    setState(() => _busy = true);
    final sent = state.editDesktopCapability(op, body);
    if (!sent && mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('发送失败（未连接）'), duration: Duration(seconds: 2)));
      return;
    }
    // 回执由 AppState 处理；等 lastCapsEdit 出现（最多 8 秒）
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final r = state.lastCapsEdit;
      if (r != null && r['op'] == op) {
        setState(() => _busy = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['ok'] == true ? '已保存' : '保存失败：${r['reason']}'),
            duration: const Duration(seconds: 3),
          ));
          if (r['ok'] == true) Navigator.of(context).pop();
        }
        return;
      }
    }
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('电脑端没有回执（可能未启动）'), duration: Duration(seconds: 3)));
    }
  }

  Future<void> _delete() async {
    final state = context.read<AppState>();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('将从电脑端删除「${_name.text.isEmpty ? widget.editId : _name.text}」，不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;

    String op = '';
    final body = <String, dynamic>{'id': widget.editId, 'key': widget.editId};
    switch (widget.kind) {
      case CapabilityKind.prompts:
        op = 'prompt-delete';
        break;
      case CapabilityKind.models:
        op = 'provider-delete';
        break;
      case CapabilityKind.mcp:
        op = 'mcp-delete';
        break;
      case CapabilityKind.skills:
        op = 'skill-delete';
        break;
    }

    setState(() => _busy = true);
    final sent = state.editDesktopCapability(op, body);
    if (!sent && mounted) {
      setState(() => _busy = false);
      return;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      final r = state.lastCapsEdit;
      if (r != null && r['op'] == op) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(r['ok'] == true ? '已删除' : '删除失败：${r['reason']}'),
            duration: const Duration(seconds: 3),
          ));
          if (r['ok'] == true) Navigator.of(context).pop();
        }
        setState(() => _busy = false);
        return;
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  static String _slug(String input) {
    final t = input.trim().toLowerCase().replaceAll(RegExp(r'[^\w-]+'), '_');
    return t.isEmpty ? 'item_${DateTime.now().millisecondsSinceEpoch % 100000}' : t;
  }
}

class _MultiSelectSheet extends StatefulWidget {
  final Map<String, String> all;
  final Set<String> initial;
  const _MultiSelectSheet({required this.all, required this.initial});

  @override
  State<_MultiSelectSheet> createState() => _MultiSelectSheetState();
}

class _MultiSelectSheetState extends State<_MultiSelectSheet> {
  late Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.66,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Expanded(
                      child: Text('选择（可多选）', style: TextStyle(fontWeight: FontWeight.bold))),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _sel),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: widget.all.entries
                    .map((e) => CheckboxListTile(
                          dense: true,
                          value: _sel.contains(e.key),
                          title: Text(e.value, style: const TextStyle(fontSize: 13.5)),
                          subtitle: e.key == e.value
                              ? null
                              : Text(e.key, style: const TextStyle(fontSize: 11)),
                          onChanged: (v) => setState(() {
                            v == true ? _sel.add(e.key) : _sel.remove(e.key);
                          }),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
