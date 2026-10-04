import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../services/app_state.dart';
import 'desktop_capabilities_screen.dart' show CapabilityKind;

/// 电脑端能力的**编辑**页（助手 / 模型(服务商) / MCP / Skill）。
///
/// 字段尽量与电脑端设置页一一对应：
///   · 助手   → render/main/components/Prompts.vue
///   · 模型   → render/main/components/Providers.vue
///   · MCP    → render/main/components/Mcp.vue
///   · Skill  → render/main/components/Skills.vue
/// API Key / token 只写不读：留空表示"不修改"，电脑端也绝不回传明文。
class DesktopCapabilityEditPage extends StatefulWidget {
  final CapabilityKind kind;

  /// 要编辑的条目标识（null = 新建）
  final String? editId;

  const DesktopCapabilityEditPage({super.key, required this.kind, this.editId});

  @override
  State<DesktopCapabilityEditPage> createState() =>
      _DesktopCapabilityEditPageState();
}

String _kindTitle(CapabilityKind k) => switch (k) {
      CapabilityKind.prompts => '助手',
      CapabilityKind.models => '服务商',
      CapabilityKind.mcp => 'MCP 工具',
      CapabilityKind.skills => 'Skill 技能',
    };

/// 一组「键=值」文本 ⇄ Map
String mapToLines(Map<String, String> m) =>
    m.entries.map((e) => '${e.key}=${e.value}').join('\n');

Map<String, String> linesToMap(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final i = t.indexOf('=');
    if (i <= 0) {
      out[t] = '';
    } else {
      out[t.substring(0, i).trim()] = t.substring(i + 1).trim();
    }
  }
  return out;
}

class _DesktopCapabilityEditPageState extends State<DesktopCapabilityEditPage> {
  final _name = TextEditingController();
  final _key = TextEditingController();
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _prompt = TextEditingController();
  final _matchRegex = TextEditingController();
  final _voice = TextEditingController();
  final _modelsText = TextEditingController();
  final _headersText = TextEditingController();
  final _command = TextEditingController();
  final _argsText = TextEditingController();
  final _envText = TextEditingController();
  final _mcpHeadersText = TextEditingController();
  final _bearer = TextEditingController();
  final _tagsText = TextEditingController();
  final _desc = TextEditingController();
  final _allowedTools = TextEditingController();
  final _instructions = TextEditingController();

  // 助手
  String _type = 'general';
  String _showMode = 'window';
  String? _model;
  String _effort = 'default';
  Set<String> _mcp = {};
  Set<String> _skills = {};
  bool _enable = true;
  bool _stream = true;
  bool _isTemperature = false;
  double _temperature = 0.7;
  bool _directNormal = true;
  bool _directFile = false;
  bool _directImage = true;
  bool _ifTextNecessary = false;
  int _winW = 540;
  int _winH = 700;
  bool _alwaysOnTop = true;
  bool _closeOnBlur = true;
  double _bgOpacity = 0.6;
  int _bgBlur = 0;
  bool _autoSaveChat = false;

  // 服务商
  String _apiType = 'chat_completions';
  int _retry = 3;

  // MCP
  String _mcpType = 'stdio';
  String _authType = 'none';
  bool _persistent = false;
  int _timeout = 120;

  // Skill
  bool _forkMode = false;

  bool _busy = false;
  bool _filled = false;

  @override
  void dispose() {
    for (final c in [
      _name, _key, _url, _apiKey, _prompt, _matchRegex, _voice, _modelsText,
      _headersText, _command, _argsText, _envText, _mcpHeadersText, _bearer,
      _tagsText, _desc, _allowedTools, _instructions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isBuiltin => (widget.editId ?? '').startsWith('builtin_');
  bool get _isNew => widget.editId == null;

  // ---------------------------------------------------------------- 回填
  void _fillOnce(AppState state) {
    if (_filled) return;
    final caps = state.capabilities;
    final id = widget.editId;

    switch (widget.kind) {
      case CapabilityKind.prompts:
        final p = id == null
            ? null
            : caps.prompts.where((e) => e.key == id).firstOrNull;
        _key.text = p?.key ?? '';
        _name.text = p?.label ?? '';
        _prompt.text = p?.promptText ?? '';
        _model = (p?.model.isNotEmpty ?? false) ? p!.model : null;
        _effort =
            (p?.reasoningEffort.isNotEmpty ?? false) ? p!.reasoningEffort : 'default';
        _mcp = p?.mcp.toSet() ?? {};
        _skills = p?.skills.toSet() ?? {};
        _enable = p?.enable ?? true;
        _type = (p?.type.isNotEmpty ?? false) ? p!.type : 'general';
        _showMode = (p?.showMode.isNotEmpty ?? false) ? p!.showMode : 'window';
        _matchRegex.text = p?.matchRegex ?? '';
        _stream = p?.stream ?? true;
        _isTemperature = p?.isTemperature ?? false;
        _temperature = p?.temperature ?? 0.7;
        _directNormal = p?.isDirectSend_normal ?? true;
        _directFile = p?.isDirectSend_file ?? false;
        _directImage = p?.isDirectSend_image ?? true;
        _ifTextNecessary = p?.ifTextNecessary ?? false;
        _voice.text = p?.voice ?? '';
        _winW = p?.windowWidth ?? 540;
        _winH = p?.windowHeight ?? 700;
        _alwaysOnTop = p?.isAlwaysOnTop ?? true;
        _closeOnBlur = p?.autoCloseOnBlur ?? true;
        _bgOpacity = p?.backgroundOpacity ?? 0.6;
        _bgBlur = p?.backgroundBlur ?? 0;
        _autoSaveChat = p?.autoSaveChat ?? false;

      case CapabilityKind.models:
        final prv =
            id == null ? null : caps.providers.where((e) => e.id == id).firstOrNull;
        _name.text = prv?.name ?? '';
        _url.text = prv?.url ?? '';
        _modelsText.text = (prv?.modelList ?? []).join('\n');
        _headersText.text = mapToLines(prv?.headers ?? const {});
        _apiType = prv?.apiType ?? 'chat_completions';
        _retry = prv?.retryCount ?? 3;
        _enable = prv?.enable ?? true;

      case CapabilityKind.mcp:
        final m =
            id == null ? null : caps.mcp.where((e) => e.id == id).firstOrNull;
        _name.text = m?.label ?? '';
        _desc.text = m?.description ?? '';
        _mcpType = (m?.type.isNotEmpty ?? false) ? m!.type : 'stdio';
        _url.text = (m?.baseUrl.isNotEmpty ?? false)
            ? m!.baseUrl
            : (m?.url ?? '');
        _command.text = m?.command ?? '';
        _argsText.text = (m?.args ?? []).join('\n');
        _envText.text = mapToLines(m?.env ?? const {});
        _mcpHeadersText.text = mapToLines(m?.headers ?? const {});
        _authType = (m?.authType.isNotEmpty ?? false) ? m!.authType : 'none';
        _persistent = m?.isPersistent ?? false;
        _timeout = m?.timeoutSeconds ?? 120;
        _tagsText.text = (m?.tags ?? []).join(', ');
        _enable = m?.isActive ?? true;

      case CapabilityKind.skills:
        final k =
            id == null ? null : caps.skills.where((e) => e.id == id).firstOrNull;
        _name.text = k?.label ?? '';
        _desc.text = k?.description ?? '';
        _allowedTools.text = (k?.allowedTools ?? []).join(', ');
        _instructions.text = k?.instructions ?? '';
        _enable = !(k?.disabled ?? false);
        _forkMode = (k?.context ?? 'normal') == 'fork';
    }
    _filled = true;
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _fillOnce(state);
    final title = '${_isNew ? "新建" : "编辑"}${_kindTitle(widget.kind)}';

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
            TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: state.capabilities.isEmpty
          ? const Center(
              child: Text('还没拿到电脑端能力', style: TextStyle(color: Colors.white38)))
          : Form(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
                children: _fields(state),
              ),
            ),
    );
  }

  List<Widget> _fields(AppState state) {
    final caps = state.capabilities;
    switch (widget.kind) {
      case CapabilityKind.prompts:
        return [
          _text('名称', _name, hint: '助手的显示名'),
          _text('标识 key', _key,
              hint: '英文/数字/下划线，电脑端用它区分助手',
              enabled: false),
          _pick('类型', _type, _promptTypes, (v) => setState(() => _type = v)),
          _pick('显示方式', _showMode, _showModes,
              (v) => setState(() => _showMode = v)),
          if (_type == 'over') _text('匹配正则', _matchRegex, hint: r'例如 ^/ai\s'),
          _text('系统提示词', _prompt, max: 8),
          _pick('模型', _model == null ? '默认（跟随电脑端）' : _modelLabel(caps, _model),
              null, null,
              onTap: () => _pickModel(state)),
          _pick('思考预算', _effort, caps.reasoningEffortOptions,
              (v) => setState(() => _effort = v)),
          _switch('流式输出', _stream, (v) => setState(() => _stream = v)),
          _switch('自定义温度', _isTemperature,
              (v) => setState(() => _isTemperature = v)),
          if (_isTemperature)
            _slider('温度', _temperature, 0, 2, (v) => setState(() => _temperature = v)),
          _multi(
            'MCP 工具',
            _mcp,
            {for (final m in caps.mcp) m.id: (m.label.isEmpty ? m.id : m.label)},
            (next) => setState(() => _mcp = next),
          ),
          _multi(
            'Skill 技能',
            _skills,
            {for (final k in caps.skills) k.id: (k.label.isEmpty ? k.id : k.label)},
            (next) => setState(() => _skills = next),
          ),
          const _SectionTitle('直接发送'),
          _switch('普通文本直接发送', _directNormal,
              (v) => setState(() => _directNormal = v)),
          _switch('文件直接发送', _directFile,
              (v) => setState(() => _directFile = v)),
          _switch('图片直接发送', _directImage,
              (v) => setState(() => _directImage = v)),
          _switch('必须有文本', _ifTextNecessary,
              (v) => setState(() => _ifTextNecessary = v)),
          const _SectionTitle('窗口'),
          _numRow('窗口宽度 / 高度', _winW, _winH,
              (w, h) => setState(() { _winW = w; _winH = h; })),
          _switch('窗口置顶', _alwaysOnTop,
              (v) => setState(() => _alwaysOnTop = v)),
          _switch('失去焦点自动关闭', _closeOnBlur,
              (v) => setState(() => _closeOnBlur = v)),
          _slider('背景不透明度', _bgOpacity, 0, 1,
              (v) => setState(() => _bgOpacity = v)),
          _intSlider('背景模糊', _bgBlur, 0, 40, (v) => setState(() => _bgBlur = v)),
          _text('语音（可留空）', _voice),
          _switch('自动保存会话', _autoSaveChat,
              (v) => setState(() => _autoSaveChat = v)),
          _switch('启用', _enable, (v) => setState(() => _enable = v)),
          if (!_isNew && widget.editId != 'AI') _deleteTile(),
        ];

      case CapabilityKind.models:
        return [
          _text('服务商名称', _name, hint: '如：Doro / Grok / 国模'),
          _pick('接口类型', _apiType, _apiTypes,
              (v) => setState(() => _apiType = v)),
          _text('接口地址', _url, hint: 'https://.../v1'),
          _text('API Key',
              _apiKey,
              hint: _isNew ? '必填' : '留空 = 不修改',
              secret: true),
          _intSlider('失败重试次数', _retry, 0, 10,
              (v) => setState(() => _retry = v)),
          _text('模型列表', _modelsText, max: 10, hint: '每行一个模型名'),
          _text('自定义请求头', _headersText,
              max: 6, hint: '每行一个：Header-Name=值'),
          _switch('启用', _enable, (v) => setState(() => _enable = v)),
          if (!_isNew) _deleteTile(),
        ];

      case CapabilityKind.mcp:
        return [
          if (_isBuiltin) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline,
                  size: 18, color: Colors.white38),
              title: Text('内置工具（${widget.editId}）',
                  style: const TextStyle(fontSize: 13)),
              subtitle: const Text('内置工具只能启用/停用，不能改参数',
                  style: TextStyle(fontSize: 11.5, color: Colors.white54)),
            ),
          ] else ...[
            _text('名称', _name),
            _text('说明', _desc),
            _pick('连接方式', _mcpType, _mcpTypes,
                (v) => setState(() => _mcpType = v)),
            if (_mcpType == 'sse' || _mcpType == 'http')
              _text('服务地址', _url, hint: 'https://...'),
            if (_mcpType == 'stdio') ...[
              _text('启动命令', _command, hint: '例如 npx'),
              _text('参数', _argsText, max: 5, hint: '每行一个参数'),
              _text('环境变量', _envText, max: 5, hint: '每行一个：KEY=值'),
            ],
            _text('请求头', _mcpHeadersText, max: 5, hint: '每行一个：Header=值'),
            _pick('认证方式', _authType, const ['none', 'bearer'],
                (v) => setState(() => _authType = v)),
            if (_authType == 'bearer')
              _text('Bearer Token', _bearer, hint: '留空 = 不修改', secret: true),
            _intSlider('超时（秒）', _timeout, 1, 1800,
                (v) => setState(() => _timeout = v)),
            _switch('保持常驻（isPersistent）', _persistent,
                (v) => setState(() => _persistent = v)),
            _text('标签', _tagsText, hint: '逗号分隔'),
          ],
          _switch('启用', _enable, (v) => setState(() => _enable = v)),
          if (!_isNew && !_isBuiltin) _deleteTile(),
        ];

      case CapabilityKind.skills:
        return [
          _text('名称', _name),
          _text('说明', _desc, max: 3),
          _switch('允许 AI 调用', _enable, (v) => setState(() => _enable = v)),
          _switch('Fork 模式（context: fork）', _forkMode,
              (v) => setState(() => _forkMode = v)),
          _text('允许使用的工具', _allowedTools, hint: '逗号分隔，留空 = 不限制'),
          _text('正文（SKILL.md 内容）', _instructions, max: 14),
          if (!_isNew) _deleteTile(),
        ];
    }
  }

  // ---------------------------------------------------------------- 小组件
  static const _promptTypes = ['general', 'over'];
  static const _showModes = ['window', 'quick'];
  static const _apiTypes = [
    'chat_completions',
    'claude',
    'codex',
    'responses',
  ];
  static const _mcpTypes = ['stdio', 'sse', 'http', 'builtin'];

  String _modelLabel(Capabilities caps, String? value) {
    if (value == null || value.isEmpty) return '默认（跟随电脑端）';
    final hit = caps.models.where((m) => m.value == value).firstOrNull;
    return hit?.displayName ?? value;
  }

  Widget _text(String label, TextEditingController c,
      {int max = 1, String? hint, bool secret = false, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: TextField(
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

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('$label：${value.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 13.5)),
      subtitle: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }

  Widget _intSlider(String label, int value, int min, int max,
      ValueChanged<int> onChanged) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('$label：$value', style: const TextStyle(fontSize: 13.5)),
      subtitle: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: (max - min) > 0 ? (max - min) : null,
        onChanged: (v) => onChanged(v.round()),
      ),
    );
  }

  Widget _numRow(String label, int a, int b, void Function(int, int) onChanged) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('$label：$a × $b', style: const TextStyle(fontSize: 13.5)),
      trailing: SizedBox(
        width: 150,
        child: Row(
          children: [
            Expanded(child: _miniNum(a, (v) => onChanged(v, b))),
            const SizedBox(width: 6),
            Expanded(child: _miniNum(b, (v) => onChanged(a, v))),
          ],
        ),
      ),
    );
  }

  Widget _miniNum(int value, ValueChanged<int> onChanged) {
    return TextFormField(
      initialValue: '$value',
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(isDense: true),
      onChanged: (t) => onChanged(int.tryParse(t.trim()) ?? value),
    );
  }

  Widget _pick(String label, String value, List<String>? options,
      ValueChanged<String>? onChanged,
      {VoidCallback? onTap}) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(value, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
      onTap: onTap ??
          (options == null || onChanged == null
              ? null
              : () async {
                  final picked = await showModalBottomSheet<String>(
                    context: context,
                    backgroundColor: const Color(0xFF1B1F2B),
                    builder: (ctx) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: options
                            .map((e) => ListTile(
                                  dense: true,
                                  title: Text(e),
                                  trailing: e == value
                                      ? const Icon(Icons.check,
                                          color: Colors.lightBlueAccent)
                                      : null,
                                  onTap: () => Navigator.pop(ctx, e),
                                ))
                            .toList(),
                      ),
                    ),
                  );
                  if (picked != null) onChanged(picked);
                }),
    );
  }

  Future<void> _pickModel(AppState state) async {
    final caps = state.capabilities;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: const Color(0xFF1B1F2B),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
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

  Widget _multi(String label, Set<String> selected, Map<String, String> all,
      ValueChanged<Set<String>> onChanged) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(
        selected.isEmpty
            ? '（不限）'
            : selected.map((id) => all[id] ?? id).join('、'),
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
        if (result != null) onChanged(result);
      },
    );
  }

  Widget _deleteTile() {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
      title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
      onTap: _busy ? null : _delete,
    );
  }

  // ---------------------------------------------------------------- 保存
  Map<String, dynamic> _body() {
    switch (widget.kind) {
      case CapabilityKind.prompts:
        return {
          'key': widget.editId ?? _slug(_name.text),
          'oldKey': widget.editId ?? _slug(_name.text),
          'label': _name.text.trim(),
          'type': _type,
          'showMode': _showMode,
          'matchRegex': _matchRegex.text,
          'prompt': _prompt.text,
          'model': _model ?? '',
          'reasoningEffort': _effort,
          'mcp': _mcp.toList(),
          'skills': _skills.toList(),
          'enable': _enable,
          'stream': _stream,
          'isTemperature': _isTemperature,
          'temperature': _temperature,
          'isDirectSend_normal': _directNormal,
          'isDirectSend_file': _directFile,
          'isDirectSend_image': _directImage,
          'ifTextNecessary': _ifTextNecessary,
          'voice': _voice.text,
          'window_width': _winW,
          'window_height': _winH,
          'isAlwaysOnTop': _alwaysOnTop,
          'autoCloseOnBlur': _closeOnBlur,
          'backgroundOpacity': _bgOpacity,
          'backgroundBlur': _bgBlur,
          'autoSaveChat': _autoSaveChat,
        };

      case CapabilityKind.models:
        return {
          'id': widget.editId ?? '',
          'name': _name.text.trim(),
          'url': _url.text.trim(),
          'apiType': _apiType,
          'retryCount': _retry,
          'enable': _enable,
          'models': _modelsText.text
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          'headers': linesToMap(_headersText.text),
          if (_apiKey.text.trim().isNotEmpty) 'apiKey': _apiKey.text.trim(),
        };

      case CapabilityKind.mcp:
        return {
          'id': widget.editId ?? _slug(_name.text),
          'name': _name.text.trim(),
          'description': _desc.text,
          'type': _mcpType,
          'baseUrl': _url.text.trim(),
          'command': _command.text.trim(),
          'args': _argsText.text
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          'env': linesToMap(_envText.text),
          'headers': linesToMap(_mcpHeadersText.text),
          'isActive': _enable,
          'isPersistent': _persistent,
          'timeoutSeconds': _timeout,
          'tags': _tagsText.text
              .split(RegExp('[,，]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          if (_authType == 'bearer' && _bearer.text.trim().isNotEmpty)
            'auth': {'type': 'bearer', 'bearerToken': _bearer.text.trim()}
          else
            'auth': {'type': 'none'},
        };

      case CapabilityKind.skills:
        return {
          'id': widget.editId,
          'name': _name.text.trim(),
          'description': _desc.text,
          'enabled': _enable,
          'forkMode': _forkMode,
          'allowedTools': _allowedTools.text,
          'instructions': _instructions.text,
        };
    }
  }

  String _op() => switch (widget.kind) {
        CapabilityKind.prompts => 'prompt-save',
        CapabilityKind.models => 'provider-save',
        CapabilityKind.mcp => 'mcp-save',
        CapabilityKind.skills => 'skill-save',
      };

  Future<void> _save() async {
    final state = context.read<AppState>();
    final op = _op();
    setState(() => _busy = true);

    final sent = state.editDesktopCapability(op, _body());
    if (!sent) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('发送失败（未连接）'), duration: Duration(seconds: 2)));
      }
      return;
    }

    final done = await _waitFor(op);
    if (!mounted) return;
    setState(() => _busy = false);
    if (done == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('电脑端没有回执（可能未启动）'),
          duration: Duration(seconds: 3)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done['ok'] == true ? '已保存' : '保存失败：${done['reason']}'),
      duration: const Duration(seconds: 3),
    ));
    if (done['ok'] == true) Navigator.of(context).pop();
  }

  Future<Map<String, dynamic>?> _waitFor(String op) async {
    final state = context.read<AppState>();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (!mounted) return null;
      final r = state.lastCapsEdit;
      if (r != null && r['op'] == op) return r;
    }
    return null;
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
            '将从电脑端删除「${_name.text.isEmpty ? widget.editId : _name.text}」，不可撤销。'),
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
    if (yes != true || !mounted) return;

    final op = switch (widget.kind) {
      CapabilityKind.prompts => 'prompt-delete',
      CapabilityKind.models => 'provider-delete',
      CapabilityKind.mcp => 'mcp-delete',
      CapabilityKind.skills => 'skill-delete',
    };
    setState(() => _busy = true);
    final sent = context
        .read<AppState>()
        .editDesktopCapability(op, {'id': widget.editId, 'key': widget.editId});
    if (!sent) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    final done = await _waitFor(op);
    if (!mounted) return;
    setState(() => _busy = false);
    if (done == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done['ok'] == true ? '已删除' : '删除失败：${done['reason']}'),
      duration: const Duration(seconds: 3),
    ));
    if (done['ok'] == true) Navigator.of(context).pop();
  }

  static String _slug(String input) {
    final t = input.trim().toLowerCase().replaceAll(RegExp(r'[^\w-]+'), '_');
    return t.isEmpty
        ? 'item_${DateTime.now().millisecondsSinceEpoch % 100000}'
        : t;
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white54)),
      );
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
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.66),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Expanded(
                      child: Text('选择（可多选）',
                          style: TextStyle(fontWeight: FontWeight.bold))),
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
                          title: Text(e.value,
                              style: const TextStyle(fontSize: 13.5)),
                          subtitle: e.key == e.value
                              ? null
                              : Text(e.key,
                                  style: const TextStyle(fontSize: 11)),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _sel.add(e.key);
                            } else {
                              _sel.remove(e.key);
                            }
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
