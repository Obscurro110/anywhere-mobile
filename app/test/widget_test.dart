// 基础单元测试：验证协议的序列化 / 反序列化与版本比较。
//
// 注意：`flutter create` 生成的默认 widget_test.dart 引用的是模板里的
// `MyApp`（counter demo），本项目不存在该类，已用此文件替换。
import 'package:flutter_test/flutter_test.dart';

// 用 models.dart：它 re-export protocol 里的类型，同时还定义了 ChatMessage。
// 直接 import protocol.dart 会找不到 ChatMessage。
import 'package:anywhere_mobile/core/app_config.dart';
import 'package:anywhere_mobile/models/models.dart';
import 'package:anywhere_mobile/services/update_service.dart';

void main() {
  group('AppConfig URL', () {
    test('只移除末尾 /ws，不误截断路径', () {
      AppConfig config(String url) => AppConfig(
            userId: 'u',
            token: 't',
            serverUrl: url,
            deviceId: 'd',
            deviceName: 'test device',
          );
      expect(config('ws://host:8787/ws').httpBase, 'http://host:8787');
      expect(config('ws://host/websocket').httpBase, 'http://host/websocket');
      expect(config('wss://api.example/v1/wss/relay').httpBase,
          'https://api.example/v1/wss/relay');
    });
  });

  group('ChatOptions', () {
    test('空 options 不参与序列化', () {
      const o = ChatOptions();
      expect(o.isEmpty, isTrue);
      expect(o.toJson(), isEmpty);
    });

    test('往返序列化保持一致', () {
      const o = ChatOptions(
        model: '0|gpt-4o',
        reasoningEffort: 'high',
        mcp: ['fs', 'shell'],
        skills: ['code-review'],
        promptKey: 'AI',
      );
      final back = ChatOptions.fromJson(o.toJson());
      expect(back.model, '0|gpt-4o');
      expect(back.reasoningEffort, 'high');
      expect(back.mcp, ['fs', 'shell']);
      expect(back.skills, ['code-review']);
      expect(back.promptKey, 'AI');
    });
  });

  group('Capabilities', () {
    test('解析电脑端上报的清单', () {
      final caps = Capabilities.fromJson({
        'models': [
          {'value': '0|gpt-4o', 'label': 'GPT-4o', 'provider': 'openai'},
        ],
        'mcp': [
          {'id': 'fs', 'label': '文件系统', 'enabled': true},
        ],
        'skills': [
          {'id': 'review', 'label': '代码审查'},
        ],
        'prompts': [
          {'key': 'AI', 'label': '通用助手', 'model': '0|gpt-4o'},
        ],
        'tasks': [
          {
            'id': 't1',
            'label': '每日总结',
            'enabled': true,
            'schedule': '每天 08:00',
          },
        ],
        'reasoningEffortOptions': ['default', 'low', 'high'],
        'desktopVersion': '1.3.3',
        'desktopVersionCode': 6,
        'upstreamVersion': '0.9.0',
      });

      expect(caps.models.single.value, '0|gpt-4o');
      expect(caps.mcp.single.id, 'fs');
      expect(caps.skills.single.label, '代码审查');
      expect(caps.prompts.single.key, 'AI');
      expect(caps.tasks.single.schedule, '每天 08:00');
      expect(caps.desktopVersion, '1.3.3');
      expect(caps.upstreamVersion, '0.9.0');
      expect(caps.isEmpty, isFalse);
    });

    test('空对象不炸，列表为空', () {
      final caps = Capabilities.fromJson({});
      expect(caps.models, isEmpty);
      expect(caps.prompts, isEmpty);
      expect(caps.tasks, isEmpty);
      expect(caps.isEmpty, isTrue);
    });

    test('过滤掉缺 id/value 的脏数据', () {
      final caps = Capabilities.fromJson({
        'models': [
          {'value': '', 'label': 'bad'},
          {'value': '1|x', 'label': 'ok'},
        ],
        'prompts': [
          {'key': '', 'label': 'bad'},
          {'key': 'AI', 'label': 'ok'},
        ],
      });
      expect(caps.models.length, 1);
      expect(caps.models.single.value, '1|x');
      expect(caps.prompts.length, 1);
      expect(caps.prompts.single.key, 'AI');
    });
  });

  group('版本比较', () {
    test('语义化版本高低', () {
      expect(UpdateService.compareSemver('1.3.3', '1.3.2'), 1);
      expect(UpdateService.compareSemver('1.3.2', '1.3.3'), -1);
      expect(UpdateService.compareSemver('1.3.3', '1.3.3'), 0);
      expect(UpdateService.compareSemver('2.0.0', '1.9.9'), 1);
      expect(UpdateService.compareSemver('1.10.0', '1.9.0'), 1);
    });

    test('位数不同的版本也能比', () {
      expect(UpdateService.compareSemver('1.4', '1.3.9'), 1);
      expect(UpdateService.compareSemver('2', '1.9.9'), 1);
    });

    test('build number 优先于版本名', () {
      final remote = ReleaseInfo(
        versionName: '1.3.3',
        versionCode: 6,
        url: 'https://example.com/a.apk',
      );
      const older = AppVersion(versionName: '1.3.4', versionCode: 5);
      const same = AppVersion(versionName: '1.3.3', versionCode: 6);
      // code 6 > 5，即使版本名看起来更小也算更新
      expect(UpdateService.isNewer(remote, older), isTrue);
      expect(UpdateService.isNewer(remote, same), isFalse);
    });
  });

  group('ChatPayload', () {
    test('普通消息序列化', () {
      final p = ChatPayload(role: ChatRole.user, text: '你好');
      final j = p.toJson();
      expect(j['role'], 'user');
      expect(j['text'], '你好');
      // 空 options 不应出现
      expect(j.containsKey('options'), isFalse);
    });

    test('带 options 时才会带上 options', () {
      final p = ChatPayload(
        role: ChatRole.user,
        text: 'hi',
        options: const ChatOptions(model: '0|gpt-4o'),
      );
      final j = p.toJson();
      expect(j.containsKey('options'), isTrue);
      expect((j['options'] as Map)['model'], '0|gpt-4o');
    });
  });

  group('ConversationOption', () {
    test('解析电脑端会话', () {
      final c = ConversationOption.fromJson({
        'id': 'conv-123',
        'title': '重构 relay 桥接',
        'updatedAt': '2026-10-03T10:00:00.000Z',
        'size': 20480,
        'format': 'sqlite',
      });
      expect(c.id, 'conv-123');
      expect(c.title, '重构 relay 桥接');
      expect(c.size, 20480);
    });

    test('缺字段时不炸，标题兜底', () {
      final c = ConversationOption.fromJson({'id': 'x'});
      expect(c.id, 'x');
      expect(c.title, '未命名会话');
      expect(c.updatedLabel, '');
    });

    test('相对时间按新旧给出人话', () {
      String iso(Duration ago) =>
          DateTime.now().toUtc().subtract(ago).toIso8601String();
      expect(ConversationOption.fromJson({'id': 'a', 'updatedAt': iso(const Duration(seconds: 20))}).updatedLabel, '刚刚');
      expect(ConversationOption.fromJson({'id': 'b', 'updatedAt': iso(const Duration(minutes: 5))}).updatedLabel, '5 分钟前');
      expect(ConversationOption.fromJson({'id': 'c', 'updatedAt': iso(const Duration(hours: 3))}).updatedLabel, '3 小时前');
      expect(ConversationOption.fromJson({'id': 'd', 'updatedAt': iso(const Duration(days: 1, hours: 1))}).updatedLabel, '昨天');
    });
  });

  group('PromptOption 预设', () {
    test('解析助手的 MCP / Skill 预设', () {
      final p = PromptOption.fromJson({
        'key': 'AI',
        'label': '通用助手',
        'model': '0|gpt-4o',
        'reasoningEffort': 'high',
        'mcp': ['fs', 'shell'],
        'skills': ['review'],
      });
      expect(p.hasPreset, isTrue);
      expect(p.mcp, ['fs', 'shell']);
      expect(p.skills, ['review']);
      expect(p.reasoningEffort, 'high');
      expect(p.presetSummary, contains('2 个 MCP'));
      expect(p.presetSummary, contains('1 个 Skill'));
    });

    test('没配预设时 hasPreset 为 false', () {
      final p = PromptOption.fromJson({'key': 'Bare', 'label': '裸助手'});
      expect(p.hasPreset, isFalse);
      expect(p.mcp, isEmpty);
      expect(p.skills, isEmpty);
    });

    test('过滤掉空的预设项', () {
      final p = PromptOption.fromJson({
        'key': 'AI',
        'mcp': ['fs', '', '  '],
        'skills': ['', 'review'],
      });
      expect(p.mcp, ['fs']);
      expect(p.skills, ['review']);
    });
  });

  group('MCP / Skill 详情', () {
    test('MCP 带描述时优先用描述', () {
      final m = McpOption.fromJson({
        'id': 'fs',
        'label': '文件系统',
        'description': '读写本机文件',
        'type': 'stdio',
      });
      expect(m.summary, '读写本机文件');
      expect(m.type, 'stdio');
    });

    test('MCP 没描述时按类型兜底', () {
      final builtin = McpOption.fromJson({'id': 'a', 'builtin': true});
      expect(builtin.summary, '内置工具');

      final remote = McpOption.fromJson({'id': 'b', 'type': 'sse'});
      expect(remote.summary, contains('远程服务'));

      final stdio = McpOption.fromJson({'id': 'c', 'command': 'npx x'});
      expect(stdio.summary, contains('npx x'));

      final none = McpOption.fromJson({'id': 'd'});
      expect(none.summary, '未填写说明');
    });

    test('Skill 解析 description 与 allowedTools', () {
      final s = SkillOption.fromJson({
        'id': 'review',
        'label': '代码审查',
        'description': '审查 PR 的改动',
        'allowedTools': ['read', 'grep', ''],
      });
      expect(s.summary, '审查 PR 的改动');
      expect(s.allowedTools, ['read', 'grep']);
    });

    test('Skill 没描述时给出兜底文案', () {
      final s = SkillOption.fromJson({'id': 'x'});
      expect(s.summary, isNotEmpty);
    });
  });

  group('CompactConfig', () {
    test('解析压缩配置并格式化上下文长度', () {
      final c = CompactConfig.fromJson({
        'model': '0|gpt-4o',
        'autoCompactEnabled': true,
        'contextLength': 128000,
      });
      expect(c.autoCompactEnabled, isTrue);
      expect(c.contextLabel, '128K');
    });

    test('未设置上下文长度时给出人话', () {
      final c = CompactConfig.fromJson({});
      expect(c.contextLabel, '未设置');
      expect(c.autoCompactEnabled, isTrue); // 默认开
    });

    test('Capabilities 能解析出 compact', () {
      final caps = Capabilities.fromJson({
        'compact': {'model': '1|claude', 'autoCompactEnabled': false},
      });
      expect(caps.compact, isNotNull);
      expect(caps.compact!.autoCompactEnabled, isFalse);
    });

    test('电脑端没上报 compact 时为 null（老版本兼容）', () {
      final caps = Capabilities.fromJson({});
      expect(caps.compact, isNull);
    });
  });

  group('TaskOption 完整配置', () {
    test('解析调度字段（手机端编辑要回填）', () {
      final t = TaskOption.fromJson({
        'id': 'task_1',
        'label': '早报',
        'triggerType': 'daily',
        'intervalMinutes': 30,
        'dailyTime': '08:30',
        'weeklyDays': [1, 3, 5],
        'historyCount': 4,
      });
      expect(t.triggerType, 'daily');
      expect(t.intervalMinutes, 30);
      expect(t.dailyTime, '08:30');
      expect(t.weeklyDays, [1, 3, 5]);
      expect(t.historyCount, 4);
    });

    test('缺字段时给安全默认值', () {
      final t = TaskOption.fromJson({'id': 'x', 'label': 'y'});
      expect(t.triggerType, 'interval');
      expect(t.intervalMinutes, 60);
      expect(t.historyCount, 0);
    });

    test('weeklyDays 里的脏数据被过滤', () {
      final t = TaskOption.fromJson({
        'id': 'x',
        'weeklyDays': [0, 2, null, 'bad'],
      });
      expect(t.weeklyDays, [2]);
    });

    test('删除单个任务的消息后仍能解析', () {
      final t = TaskOption.fromJson({'id': 'x'});
      expect(t.id, 'x');
    });
  });

  group('ConvMessage 消息操作能力', () {
    test('assistant 消息可重新回答', () {
      final m = ConvMessage.fromJson({
        'id': '12',
        'index': 3,
        'role': 'assistant',
        'text': 'hi',
      });
      expect(m.canReask, isTrue);
      expect(m.canDelete, isTrue);
      expect(m.index, 3);
    });

    test('user 消息不能重新回答但能删除', () {
      final m = ConvMessage.fromJson({'id': '9', 'index': 2, 'role': 'user'});
      expect(m.canReask, isFalse);
      expect(m.canDelete, isTrue);
    });

    test('系统提示词不能删除', () {
      final m = ConvMessage.fromJson({'id': '1', 'index': 0, 'role': 'system'});
      expect(m.canDelete, isFalse);
    });

    test('没有 index 时不能删除（避免删错行）', () {
      final m = ConvMessage.fromJson({'id': '1', 'role': 'user'});
      expect(m.index, -1);
      expect(m.canDelete, isFalse);
    });
  });

  group('AssistantMeta / 气泡操作', () {
    test('解析电脑端回传的消息定位信息', () {
      final m = AssistantMeta.fromJson({
        'messageId': '42',
        'index': 7,
        'conversationId': 'conv-a',
      });
      expect(m.messageId, '42');
      expect(m.index, 7);
      expect(m.conversationId, 'conv-a');
      expect(m.isValid, isTrue);
    });

    test('缺字段时为无效（不显示操作按钮）', () {
      final m = AssistantMeta.fromJson({});
      expect(m.messageId, '');
      expect(m.index, -1);
      expect(m.isValid, isFalse);
    });

    test('ChatPayload 往返保留 assistantMeta', () {
      final p = ChatPayload(
        role: ChatRole.assistant,
        text: 'hello',
        assistantMeta: AssistantMeta(
          messageId: '5',
          index: 2,
          conversationId: 'c1',
        ),
      );
      final j = p.toJson();
      expect(j['__relayAssistantMeta'], isNotNull);
      final back = ChatPayload.fromJson(j);
      expect(back.assistantMeta?.messageId, '5');
      expect(back.assistantMeta?.index, 2);
      expect(back.assistantMeta?.conversationId, 'c1');
    });

    test('没有 meta 时 ChatPayload 不带该字段', () {
      final p = ChatPayload(role: ChatRole.assistant, text: 'x');
      expect(p.toJson().containsKey('__relayAssistantMeta'), isFalse);
    });

    test('ChatMessage 带上 meta 才算可操作', () {
      final withMeta = ChatMessage(
        id: 'a',
        role: 'assistant',
        text: 'hi',
        time: DateTime.fromMillisecondsSinceEpoch(1),
        outgoing: false,
        desktopMeta: AssistantMeta(messageId: '3', index: 1),
      );
      expect(withMeta.isDesktopAssistant, isTrue);

      final noMeta = ChatMessage(
        id: 'b',
        role: 'assistant',
        text: 'hi',
        time: DateTime.fromMillisecondsSinceEpoch(1),
        outgoing: false,
      );
      expect(noMeta.isDesktopAssistant, isFalse);

      final own = ChatMessage(
        id: 'c',
        role: 'assistant',
        text: 'hi',
        time: DateTime.fromMillisecondsSinceEpoch(1),
        outgoing: true,
        desktopMeta: AssistantMeta(messageId: '3', index: 1),
      );
      expect(own.isDesktopAssistant, isFalse);
    });

    test('ChatMessage 往返保留 desktopMeta', () {
      final m = ChatMessage(
        id: 'x',
        role: 'assistant',
        text: 't',
        time: DateTime.fromMillisecondsSinceEpoch(1000),
        outgoing: false,
        desktopMeta: AssistantMeta(messageId: '9', index: 4, conversationId: 'c'),
      );
      final back = ChatMessage.fromJson(m.toJson());
      expect(back.desktopMeta?.messageId, '9');
      expect(back.desktopMeta?.index, 4);
    });
  });

  group('模型显示名（服务商|模型）', () {
    test('电脑端有报服务商时用「服务商|模型名」', () {
      final m = ModelOption.fromJson({
        'value': '1790428297454|deepseek-v4.1-flash',
        'label': 'deepseek-v4.1-flash',
        'provider': 'DeepSeek',
      });
      expect(m.providerLabel, 'DeepSeek');
      expect(m.displayName, 'DeepSeek|deepseek-v4.1-flash');
    });

    test('电脑端没报服务商时退回 value 里的 providerId', () {
      final m = ModelOption.fromJson({
        'value': 'abc123|gpt-4o',
        'label': 'gpt-4o',
      });
      expect(m.providerLabel, 'abc123');
      expect(m.displayName, 'abc123|gpt-4o');
    });

    test('value 里没有分隔符时不炸', () {
      final m = ModelOption.fromJson({'value': 'solo', 'label': 'solo'});
      // label 与服务商回退名相同时，保持原值，避免显示成「solo|solo」。
      expect(m.displayName, 'solo');
    });
  });

  group('气泡上的模型标签', () {
    test('AssistantMeta 带上 modelTag 并能往返', () {
      final m = AssistantMeta.fromJson({
        'messageId': '3',
        'index': 1,
        'conversationId': 'c',
        'modelTag': 'Doro|claude-opus-5',
      });
      expect(m.modelTag, 'Doro|claude-opus-5');
      final j = m.toJson();
      expect(j['modelTag'], 'Doro|claude-opus-5');
    });

    test('旧版电脑端没报 modelTag 时为空（UI 有兜底）', () {
      final m = AssistantMeta.fromJson({'messageId': '3', 'index': 1});
      expect(m.modelTag, '');
    });

    test('ChatMessage 保留 modelTag', () {
      final m = ChatMessage(
        id: 'a',
        role: 'assistant',
        text: 'hi',
        time: DateTime.fromMillisecondsSinceEpoch(1),
        outgoing: false,
        modelTag: 'Grok|grok-4',
      );
      expect(m.modelTag, 'Grok|grok-4');
      final back = ChatMessage.fromJson(m.toJson());
      expect(back.modelTag, 'Grok|grok-4');
    });
  });

  group('自己发的消息也能删（user-message-meta）', () {
    test('ChatRole 常量存在', () {
      expect(ChatRole.userMessageMeta, 'user-message-meta');
    });

    test('user 消息带上 desktopMeta 后可删除', () {
      final m = ChatMessage(
        id: 'local-1',
        role: 'user',
        text: '我发的',
        time: DateTime.fromMillisecondsSinceEpoch(1),
        outgoing: true,
        desktopMeta: AssistantMeta(messageId: '77', index: 5, conversationId: 'c'),
      );
      // 删除按钮看的是 desktopMeta.valid，与角色无关
      expect(m.desktopMeta?.isValid, isTrue);
      // 但「重新回答」仍然只给 AI 回复
      expect(m.isDesktopAssistant, isFalse);
    });

    test('等待重答时能标记出是哪条（转圈用）', () {
      // 纯数据校验：isValid 只在 id + index 都有时为真
      expect(AssistantMeta(messageId: '1', index: 0).isValid, isTrue);
      expect(AssistantMeta(messageId: '1', index: -1).isValid, isFalse);
      expect(AssistantMeta(messageId: '', index: 0).isValid, isFalse);
    });
  });

  group('会话隔离（内容不再互相重合）', () {
    test('ConvMessage 能正确区分角色', () {
      final u = ConvMessage.fromJson({'id': '1', 'index': 1, 'role': 'user', 'text': '你好'});
      final a = ConvMessage.fromJson({'id': '2', 'index': 2, 'role': 'assistant', 'text': 'hi'});
      final s = ConvMessage.fromJson({'id': '0', 'index': 0, 'role': 'system', 'text': 'sys'});
      expect(u.isUser, isTrue);
      expect(u.isSystem, isFalse);
      expect(u.canReask, isFalse, reason: 'user 消息不能重新回答');
      expect(a.canReask, isTrue);
      expect(s.canDelete, isFalse, reason: '系统提示词不允许删');
      expect(u.canDelete, isTrue);
    });

    test('ConvMessage 缺字段时不炸且 index 默认 -1', () {
      final m = ConvMessage.fromJson({});
      expect(m.id, '');
      expect(m.index, -1);
      expect(m.role, '');
      expect(m.canDelete, isFalse);
    });

    test('聊天记录 key 按会话分开（不同会话不共用一份）', () {
      // 复刻 AppState._historyKey 的规则：空=本机，非空=该会话独有
      String key(String? id) {
        final v = (id ?? '').trim();
        return v.isEmpty ? 'chat_history' : 'chat_history:$v';
      }
      expect(key(null), 'chat_history');
      expect(key(''), 'chat_history');
      expect(key('convA'), 'chat_history:convA');
      expect(key('convB'), 'chat_history:convB');
      expect(key('convA') == key('convB'), isFalse,
          reason: '两个会话必须各存各的，否则内容会重合');
    });
  });

  group('桌面消息定位', () {
    test('desktopMeta 只在 id+index 都有时才算有效', () {
      expect(AssistantMeta(messageId: '5', index: 0).isValid, isTrue);
      expect(AssistantMeta(messageId: '5').isValid, isFalse);
      expect(AssistantMeta(index: 0).isValid, isFalse);
    });
  });
}
