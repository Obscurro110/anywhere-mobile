// 基础单元测试：验证协议的序列化 / 反序列化与版本比较。
//
// 注意：`flutter create` 生成的默认 widget_test.dart 引用的是模板里的
// `MyApp`（counter demo），本项目不存在该类，已用此文件替换。
import 'package:flutter_test/flutter_test.dart';

import 'package:anywhere_mobile/core/protocol.dart';
import 'package:anywhere_mobile/services/update_service.dart';

void main() {
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
        compress: true,
        promptKey: 'AI',
      );
      final back = ChatOptions.fromJson(o.toJson());
      expect(back.model, '0|gpt-4o');
      expect(back.reasoningEffort, 'high');
      expect(back.mcp, ['fs', 'shell']);
      expect(back.skills, ['code-review']);
      expect(back.compress, isTrue);
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
}
