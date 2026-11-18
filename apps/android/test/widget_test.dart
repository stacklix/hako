import 'package:doppel/main.dart';
import 'package:doppel/pages/forwarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpDoppelApp(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const DoppelApp(autoRequestPermissionsOnStart: false),
    );
  }

  Future<void> pumpDoppelAppWithPlatformSnapshot(
    WidgetTester tester,
    Map<String, Object?> snapshot,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'getSnapshot':
              return snapshot;
            case 'saveConfig':
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('doppel/platform'),
            null,
          );
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const DoppelApp(autoRequestPermissionsOnStart: false),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addDialogValue(WidgetTester tester, String value) async {
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, value);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisibleText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  testWidgets('home dashboard shows compact Doppel status overview', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    expect(find.text('Doppel'), findsOneWidget);
    expect(find.text('短信转发与远程拨号助手'), findsOneWidget);
    expect(find.text('运行状态'), findsOneWidget);
    expect(find.text('等待授权'), findsOneWidget);
    expect(find.text('--'), findsNothing);
    expect(find.text('0'), findsWidgets);
    expect(find.text('今日短信事件'), findsOneWidget);
    expect(find.text('累计短信事件'), findsOneWidget);
    expect(find.text('今日来电事件'), findsOneWidget);
    expect(find.text('累计来电事件'), findsOneWidget);
    expect(find.text('今日转发短信'), findsOneWidget);
    expect(find.text('累计转发短信'), findsOneWidget);
    expect(find.text('今日短信指令'), findsOneWidget);
    expect(find.text('累计短信指令'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.text('转发方式'), findsNothing);
    expect(find.text('CALL / SMS 指令已开启'), findsNothing);
    expect(find.text('最近事件'), findsOneWidget);
    expect(find.text('暂无事件'), findsOneWidget);
    expect(find.text('短信已转发'), findsNothing);
    expect(find.text('指令已执行'), findsNothing);
  });

  testWidgets('home metrics and sim list use platform snapshot data', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'permissions': {'sms': true, 'phone': true},
      'simCards': [
        {
          'subscriptionId': 7,
          'slotIndex': 0,
          'displayName': '工作卡',
          'carrierName': '中国移动',
          'number': '+8613800138000',
        },
      ],
      'events': [
        {'type': 'sms_received', 'timestamp': DateTime.now().toIso8601String()},
        {'type': 'sms_command', 'timestamp': DateTime.now().toIso8601String()},
        {
          'type': 'sms_forwarded',
          'timestamp': DateTime.now().toIso8601String(),
        },
        {
          'type': 'call_received',
          'timestamp': DateTime.now().toIso8601String(),
        },
        {
          'type': 'sms_received',
          'timestamp': DateTime.now()
              .subtract(const Duration(days: 2))
              .toIso8601String(),
        },
      ],
    });

    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('--'), findsNothing);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('工作卡 · +8613800138000'), findsOneWidget);
  });

  testWidgets('home recent events show newest platform event first', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': DateTime.now()
              .subtract(const Duration(minutes: 10))
              .toIso8601String(),
          'detail': '来自旧号码的普通短信',
        },
        {
          'type': 'sms_received',
          'timestamp': DateTime.now().toIso8601String(),
          'detail': '来自 15712062545 的普通短信',
        },
      ],
    });

    final latestTop = tester.getTopLeft(find.text('来自 15712062545 的普通短信'));
    final oldTop = tester.getTopLeft(find.text('来自旧号码的普通短信'));

    expect(latestTop.dy, lessThan(oldTop.dy));
  });

  testWidgets('home recent events only show events from the last day', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': DateTime.now()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
          'detail': '来自昨天之前的短信',
        },
        {
          'type': 'sms_received',
          'timestamp': DateTime.now().toIso8601String(),
          'detail': '来自今天的短信',
        },
      ],
    });

    expect(find.text('来自今天的短信'), findsOneWidget);
    expect(find.text('来自昨天之前的短信'), findsNothing);
  });

  testWidgets(
    'home recent events show business events without imported duplicates',
    (WidgetTester tester) async {
      await pumpDoppelAppWithPlatformSnapshot(tester, {
        'events': [
          {
            'type': 'sms_received',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '普通短信',
          },
          {
            'type': 'sms_received',
            'source': 'system_sms',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '系统导入短信',
          },
          {
            'type': 'call_received',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '来自 15712062545 的来电',
          },
          {
            'type': 'call_out_command',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '根据 15712062545 的指令呼出 18312662545',
          },
          {
            'type': 'sms_command',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '来自 15712062545 的指令',
          },
          {
            'type': 'sms_sent_command',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '根据 15712062545 的指令发送短信到 18312662545',
          },
          {
            'type': 'sms_forwarded',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '转发记录',
          },
          {
            'type': 'sms_pipeline_debug',
            'timestamp': DateTime.now().toIso8601String(),
            'detail': '调试事件',
          },
        ],
      });

      expect(find.text('普通短信'), findsOneWidget);
      expect(find.text('系统导入短信'), findsNothing);
      expect(find.text('来自 15712062545 的来电'), findsOneWidget);
      expect(find.text('根据 15712062545 的指令呼出 18312662545'), findsOneWidget);
      expect(find.text('来自 15712062545 的指令'), findsOneWidget);
      expect(find.text('根据 15712062545 的指令发送短信到 18312662545'), findsOneWidget);
      expect(find.text('转发记录'), findsNothing);
      expect(find.text('调试事件'), findsNothing);
      expect(find.text('收到短信'), findsOneWidget);
      expect(find.text('电话呼入'), findsOneWidget);
      expect(find.text('电话呼出'), findsOneWidget);
      expect(find.text('收到指令'), findsOneWidget);
      expect(find.text('发送短信'), findsOneWidget);
    },
  );

  testWidgets('command events show sender recipient type and command content', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_command',
          'timestamp': DateTime.now().toIso8601String(),
          'detail': '来自 15712062545 的短信指令',
          'from': '15712062545',
          'to': 'SIM 1',
          'commandType': 'SMS',
          'commandContent': 'DOPPEL SMS 18312662545 你好',
        },
      ],
    });

    expect(find.text('收到指令'), findsOneWidget);
    expect(find.textContaining('发送号码: 15712062545'), findsOneWidget);
    expect(find.textContaining('接收号码: SIM 1'), findsOneWidget);
    expect(find.textContaining('指令类型: SMS'), findsOneWidget);
    expect(
      find.textContaining('指令内容: DOPPEL SMS 18312662545 你好'),
      findsOneWidget,
    );
  });

  testWidgets('event rows show event time in local timezone', (
    WidgetTester tester,
  ) async {
    final timestamp = DateTime.now();
    final expectedHour = timestamp.hour.toString().padLeft(2, '0');
    final expectedMinute = timestamp.minute.toString().padLeft(2, '0');
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'call_received',
          'timestamp': timestamp.toIso8601String(),
          'detail': '来自 15712062545 的来电',
        },
      ],
    });

    expect(find.text('$expectedHour:$expectedMinute'), findsOneWidget);
  });

  testWidgets('home sms event rows show structured message details', (
    WidgetTester tester,
  ) async {
    final timestamp = DateTime.now();
    final expectedDate = timestamp.year.toString().padLeft(4, '0');
    final expectedMonth = timestamp.month.toString().padLeft(2, '0');
    final expectedDay = timestamp.day.toString().padLeft(2, '0');
    final expectedHour = timestamp.hour.toString().padLeft(2, '0');
    final expectedMinute = timestamp.minute.toString().padLeft(2, '0');
    final expectedSecond = timestamp.second.toString().padLeft(2, '0');
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': timestamp.toIso8601String(),
          'from': '15712062545',
          'to': '+8617318001857',
          'content': '验证码 123456',
        },
      ],
    });

    expect(find.text('收到短信'), findsOneWidget);
    expect(
      find.textContaining(
        '时间: $expectedDate-$expectedMonth-$expectedDay $expectedHour:$expectedMinute:$expectedSecond',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('发送号码: 15712062545'), findsOneWidget);
    expect(find.textContaining('接收号码: +8617318001857'), findsOneWidget);
    expect(find.textContaining('短信内容: 验证码 123456'), findsOneWidget);
  });

  testWidgets('home sms event rows show structured content from snapshot', (
    WidgetTester tester,
  ) async {
    final timestamp = DateTime.now();
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': timestamp.toIso8601String(),
          'detail': '来自 10000 的普通短信',
          'from': '10000',
          'to': '+8617318001857',
          'content': '套餐余量提醒',
        },
      ],
    });

    expect(find.text('收到短信'), findsOneWidget);
    expect(find.textContaining('发送号码: 10000'), findsOneWidget);
    expect(find.textContaining('短信内容: 套餐余量提醒'), findsOneWidget);
  });

  testWidgets('home long sms event can open full detail', (
    WidgetTester tester,
  ) async {
    final longContent = List.filled(8, '这是一段很长的短信内容').join('，');
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': DateTime.now().toIso8601String(),
          'from': '10000',
          'to': '+8617318001857',
          'content': longContent,
        },
      ],
    });

    await tester.tap(find.text('收到短信'));
    await tester.pumpAndSettle();

    expect(find.text('事件详情'), findsOneWidget);
    expect(find.text(longContent), findsOneWidget);
  });

  testWidgets('home ignores imported sms history older than 30 days', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'source': 'system_sms',
          'timestamp': DateTime.now()
              .subtract(const Duration(days: 31))
              .toIso8601String(),
          'detail': '来自 15712062545 的历史短信',
        },
      ],
    });

    expect(find.text('0'), findsWidgets);
    expect(find.text('来自 15712062545 的历史短信'), findsNothing);
    expect(find.text('暂无事件'), findsOneWidget);
  });

  testWidgets(
    'home dashboard refreshes when platform snapshot adds sms events',
    (WidgetTester tester) async {
      Map<String, Object?> snapshot = {'events': <Map<String, Object?>>[]};

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
            MethodCall call,
          ) async {
            switch (call.method) {
              case 'getSnapshot':
                return snapshot;
              case 'saveConfig':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('doppel/platform'),
              null,
            );
      });

      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const DoppelApp(autoRequestPermissionsOnStart: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('0'), findsWidgets);

      snapshot = {
        'events': [
          {
            'type': 'sms_received',
            'timestamp': DateTime.now().toIso8601String(),
          },
        ],
      };

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(find.text('1'), findsWidgets);
    },
  );

  testWidgets('home refreshes when native pushes a snapshot change', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'permissions': {'sms': true, 'phone': true},
      'events': const [],
    });

    expect(find.text('暂无事件'), findsOneWidget);

    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'doppel/platform',
          codec.encodeMethodCall(
            MethodCall('snapshotChanged', {
              'permissions': {'sms': true, 'phone': true},
              'events': [
                {
                  'type': 'sms_received',
                  'timestamp': DateTime.now().toIso8601String(),
                  'detail': '来自 15712062545 的普通短信',
                },
              ],
            }),
          ),
          (_) {},
        );
    await tester.pumpAndSettle();

    expect(find.text('收到短信'), findsOneWidget);
    expect(find.text('来自 15712062545 的普通短信'), findsOneWidget);
    expect(find.text('暂无事件'), findsNothing);
  });

  testWidgets('log page renders business events without pipeline diagnostics', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'operation_log',
          'detail': '邮件转发失败：scliqiao@qq.com',
          'timestamp': DateTime.now().toIso8601String(),
        },
        {
          'type': 'sms_pipeline_debug',
          'detail': '收到短信广播，已加入后台任务队列',
          'timestamp': DateTime.now().toIso8601String(),
        },
      ],
    });

    await tester.tap(find.text('日志').last);
    await tester.pumpAndSettle();

    expect(find.text('业务日志'), findsOneWidget);
    expect(find.text('邮件转发失败：scliqiao@qq.com'), findsOneWidget);
    expect(find.text('短信后台链路'), findsNothing);
    expect(find.text('收到短信广播，已加入后台任务队列'), findsNothing);
  });

  testWidgets('log page long sms event can open full detail', (
    WidgetTester tester,
  ) async {
    final longContent = List.filled(8, '日志里的长短信内容').join('，');
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'events': [
        {
          'type': 'sms_received',
          'timestamp': DateTime.now().toIso8601String(),
          'from': '10000',
          'to': '+8617318001857',
          'content': longContent,
        },
      ],
    });

    await tester.tap(find.text('日志').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('收到短信'));
    await tester.pumpAndSettle();

    expect(find.text('事件详情'), findsOneWidget);
    expect(find.text(longContent), findsOneWidget);
  });

  testWidgets('forwarding and command pages restore platform config', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'permissions': {'sms': true, 'phone': true},
      'config': {
        'forwarding': {
          'smsTargets': [
            {'value': '+86 13600136000', 'enabled': true},
          ],
          'emailTargets': [
            {'value': 'ops@example.com', 'enabled': false},
          ],
          'httpTargets': [
            {'value': 'https://example.com/sms', 'enabled': true},
          ],
          'smtp': {
            'host': 'smtp.example.com',
            'port': '587',
            'fromEmail': 'sender@example.com',
            'username': 'sender@example.com',
            'password': 'secret',
          },
        },
        'commands': {
          'callEnabled': false,
          'smsEnabled': true,
          'trustedNumbers': [
            {'number': '+86 13700137000'},
          ],
        },
      },
    });

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('+86 13600136000'), findsOneWidget);

    await tester.tap(find.text('转发到邮箱'));
    await tester.pumpAndSettle();

    expect(find.text('ops@example.com'), findsOneWidget);
    expect(find.text('sender@example.com'), findsOneWidget);
    expect(find.text('smtp.example.com:587'), findsOneWidget);

    await tester.tap(find.text('推送到服务器'));
    await tester.pumpAndSettle();

    expect(find.text('https://example.com/sms'), findsOneWidget);

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    expect(find.text('+86 13700137000'), findsOneWidget);
    expect(find.text('可信号码'), findsWidgets);
  });

  testWidgets('phone forwarding save does not overwrite email settings', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? savedConfig;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'getSnapshot':
              return {
                'config': {
                  'forwarding': {
                    'emailTargets': [
                      {'value': 'ops@example.com', 'enabled': true},
                    ],
                    'smtp': {
                      'host': 'smtp.example.com',
                      'port': '587',
                      'fromEmail': 'sender@example.com',
                      'username': 'sender@example.com',
                      'password': 'secret',
                    },
                  },
                },
              };
            case 'saveConfig':
              savedConfig = Map<String, Object?>.from(call.arguments as Map);
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('doppel/platform'),
            null,
          );
    });

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const DoppelApp(autoRequestPermissionsOnStart: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();
    await tapVisibleText(tester, '添加手机号');
    await addDialogValue(tester, '18312662545');

    final forwarding = Map<String, Object?>.from(
      savedConfig?['forwarding'] as Map,
    );
    expect(forwarding.containsKey('smsTargets'), isTrue);
    expect(forwarding.containsKey('emailTargets'), isFalse);
    expect(forwarding.containsKey('smtp'), isFalse);
    expect(forwarding.containsKey('httpTargets'), isFalse);
  });

  testWidgets(
    'forwarding page is not recreated when forwarding config changes',
    (WidgetTester tester) async {
      await pumpDoppelAppWithPlatformSnapshot(tester, {
        'config': {
          'forwarding': {
            'emailTargets': [
              {'value': 'ops@example.com', 'enabled': true},
            ],
          },
        },
      });

      await tester.tap(find.text('转发').last);
      await tester.pumpAndSettle();

      final page = tester.widget<ForwardingPage>(find.byType(ForwardingPage));
      expect(page.key, isNull);
    },
  );

  testWidgets('empty event state is centered in its card', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    final emptyStateCenter = tester.getCenter(find.text('暂无事件'));

    expect((emptyStateCenter.dx - 195).abs(), lessThan(24));
  });

  testWidgets('bottom navigation exposes forwarding command and log pages', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('转发到手机号'), findsWidgets);
    expect(find.text('转发到邮箱'), findsOneWidget);
    expect(find.text('推送到服务器'), findsOneWidget);

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    expect(find.text('短信指令'), findsOneWidget);
    expect(find.text('HTTP 指令'), findsOneWidget);
    expect(find.text('可信号码'), findsWidgets);
    expect(find.text('DOPPEL CALL 13800138000'), findsOneWidget);
    expect(find.text('DOPPEL SMS 13800138000 你好'), findsOneWidget);

    await tester.tap(find.text('日志').last);
    await tester.pumpAndSettle();

    expect(find.text('事件日志'), findsOneWidget);
    expect(find.text('暂无日志'), findsOneWidget);
  });

  testWidgets('settings button opens permission and runtime settings', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('系统设置'), findsOneWidget);
    expect(find.text('权限状态'), findsOneWidget);
    expect(find.text('远程 HTTP 控制'), findsNothing);
    expect(find.text('自动接听'), findsOneWidget);
    expect(find.text('日志保留天数'), findsOneWidget);
  });

  testWidgets('command page can configure remote HTTP control', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? savedConfig;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'getSnapshot':
              return {
                'remoteControlStatus': {
                  'ipAddresses': ['192.168.1.23'],
                  'isRunning': true,
                  'port': 18080,
                },
                'config': {
                  'remoteControl': {
                    'enabled': false,
                    'port': '18080',
                    'password': '',
                    'token': 'old-token',
                  },
                },
              };
            case 'saveConfig':
              savedConfig = Map<String, Object?>.from(call.arguments as Map);
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('doppel/platform'),
            null,
          );
    });

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const DoppelApp(autoRequestPermissionsOnStart: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    expect(find.text('短信指令'), findsOneWidget);
    expect(find.text('HTTP 指令'), findsOneWidget);
    expect(find.text('远程 HTTP 控制'), findsOneWidget);
    expect(find.text('运行状态'), findsOneWidget);
    expect(find.text('当前 IP'), findsOneWidget);
    expect(find.text('192.168.1.23'), findsOneWidget);
    expect(find.text('服务状态'), findsOneWidget);
    expect(find.text('运行中，端口 18080'), findsOneWidget);
    expect(find.text('服务配置'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);
    expect(find.text('保存远程控制'), findsNothing);
    await tester.tap(find.byTooltip('启用远程 HTTP 控制'));
    await tester.pumpAndSettle();
    expect(find.text('保存远程控制'), findsNothing);
    expect(savedConfig, containsPair('remoteControl', {'enabled': true}));
    savedConfig = null;
    await tester.enterText(find.bySemanticsLabel('监听端口'), '19090');
    await tester.enterText(find.bySemanticsLabel('管理密码'), 'secret-pass');
    await tester.enterText(find.bySemanticsLabel('接口 Token'), 'api-token');
    await tester.pumpAndSettle();
    expect(savedConfig, isNull);
    await tester.ensureVisible(find.text('保存远程控制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存远程控制'));
    await tester.pumpAndSettle();

    expect(savedConfig, isNotNull);
    expect(
      savedConfig,
      containsPair('remoteControl', {
        'port': '19090',
        'password': 'secret-pass',
        'token': 'api-token',
      }),
    );
  });

  testWidgets('remote control password visibility can be toggled', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    Finder passwordField() {
      return find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '管理密码',
      );
    }

    final passwordTextField = tester.widget<TextField>(passwordField());
    expect(passwordTextField.decoration?.suffixIcon, isA<IconButton>());
    expect(tester.widget<TextField>(passwordField()).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示管理密码'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(passwordField()).obscureText, isFalse);
    await tester.tap(find.byTooltip('隐藏管理密码'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(passwordField()).obscureText, isTrue);
  });

  testWidgets(
    'remote control password input is not reset by snapshot refresh',
    (WidgetTester tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
            MethodCall call,
          ) async {
            switch (call.method) {
              case 'getSnapshot':
                return {
                  'config': {
                    'remoteControl': {
                      'enabled': false,
                      'port': '18080',
                      'password': '',
                      'token': '',
                    },
                  },
                };
              case 'saveConfig':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('doppel/platform'),
              null,
            );
      });

      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const DoppelApp(autoRequestPermissionsOnStart: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('指令').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.bySemanticsLabel('管理密码'), 'abc123');

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'abc123'), findsOneWidget);
    },
  );

  testWidgets('command page can add a trusted phone number', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加号码'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '+86 13700137000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('+86 13700137000'), findsOneWidget);
    expect(find.text('1 个'), findsOneWidget);
  });

  testWidgets('forwarding page can configure phone email and http targets', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('+86 13800138000'), findsNothing);
    expect(find.text('notify@example.com'), findsNothing);
    expect(find.text('https://example.com/doppel'), findsNothing);

    await tapVisibleText(tester, '添加手机号');
    await addDialogValue(tester, '+86 13600136000');
    expect(find.text('+86 13600136000'), findsOneWidget);
    expect(find.byTooltip('删除 +86 13600136000'), findsOneWidget);

    await tester.tap(find.text('转发到邮箱'));
    await tester.pumpAndSettle();
    await tapVisibleText(tester, '添加邮箱');
    await addDialogValue(tester, 'ops@example.com');
    expect(find.text('ops@example.com'), findsOneWidget);
    expect(find.byTooltip('删除 ops@example.com'), findsOneWidget);

    await tester.tap(find.text('推送到服务器'));
    await tester.pumpAndSettle();
    await tapVisibleText(tester, '添加 HTTP');
    await addDialogValue(tester, 'https://example.com/sms');
    expect(find.text('https://example.com/sms'), findsOneWidget);
    expect(find.byTooltip('删除 https://example.com/sms'), findsOneWidget);
  });

  testWidgets('command page can edit and delete trusted phone numbers', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('指令').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加号码'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '+86 13500135000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑 +86 13500135000'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '+86 13500135001');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('+86 13500135001'), findsOneWidget);
    expect(find.text('可信号码'), findsWidgets);

    await tester.tap(find.byTooltip('编辑 +86 13500135001'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('+86 13500135001'), findsNothing);
    expect(find.text('0 个'), findsOneWidget);
  });

  testWidgets('email forwarding tab configures SMTP sender settings', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('转发到邮箱'));
    await tester.pumpAndSettle();

    expect(find.text('SMTP 发件人'), findsOneWidget);
    expect(find.text('未配置发件邮箱'), findsOneWidget);

    await tester.tap(find.text('配置发件人'));
    await tester.pumpAndSettle();

    final portField = tester.widget<TextField>(
      find.widgetWithText(TextField, '端口'),
    );
    expect(portField.controller?.text, '465');

    await tester.enterText(
      find.widgetWithText(TextField, 'SMTP Host'),
      'smtp.example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, '端口'), '587');
    await tester.enterText(
      find.widgetWithText(TextField, '发件邮箱'),
      'sender@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '账号'),
      'sender@example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, '密码/授权码'), 'secret');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('sender@example.com'), findsOneWidget);
    expect(find.text('smtp.example.com:587'), findsOneWidget);
    expect(find.byTooltip('编辑发件人'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '配置发件人'), findsNothing);
  });

  testWidgets('email forwarding tab defaults blank smtp port to ssl 465', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发到邮箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置发件人'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'SMTP Host'),
      'smtp.example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '发件邮箱'),
      'sender@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '账号'),
      'sender@example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, '密码/授权码'), 'secret');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('sender@example.com'), findsOneWidget);
    expect(find.text('smtp.example.com:465'), findsOneWidget);
  });

  testWidgets('smtp settings dialog can reveal password text', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发到邮箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置发件人'));
    await tester.pumpAndSettle();

    TextField passwordField() {
      return tester.widget<TextField>(find.widgetWithText(TextField, '密码/授权码'));
    }

    expect(passwordField().decoration?.suffixIcon, isA<IconButton>());
    expect(passwordField().obscureText, isTrue);
    expect(find.byTooltip('显示密码'), findsOneWidget);

    await tester.tap(find.byTooltip('显示密码'));
    await tester.pumpAndSettle();

    expect(passwordField().obscureText, isFalse);
    expect(find.byTooltip('隐藏密码'), findsOneWidget);

    await tester.tap(find.byTooltip('隐藏密码'));
    await tester.pumpAndSettle();

    expect(passwordField().obscureText, isTrue);
  });

  testWidgets('phone forwarding tab can choose sms sending sim', (
    WidgetTester tester,
  ) async {
    await pumpDoppelAppWithPlatformSnapshot(tester, {
      'simCards': [
        {
          'subscriptionId': 7,
          'slotIndex': 0,
          'displayName': '工作卡',
          'carrierName': '中国移动',
          'number': '+8613800138000',
        },
        {
          'subscriptionId': 8,
          'slotIndex': 1,
          'displayName': '生活卡',
          'carrierName': '中国联通',
          'number': '+8613900139000',
        },
      ],
    });

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('短信发送卡'), findsOneWidget);
    expect(find.text('工作卡 · +8613800138000'), findsOneWidget);

    await tester.tap(find.byTooltip('选择短信发送卡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生活卡 · +8613900139000').last);
    await tester.pumpAndSettle();

    expect(find.text('生活卡 · +8613900139000'), findsOneWidget);
  });

  testWidgets('phone forwarding tab shows real empty sim state', (
    WidgetTester tester,
  ) async {
    await pumpDoppelApp(tester);

    await tester.tap(find.text('转发').last);
    await tester.pumpAndSettle();

    expect(find.text('未读取到 SIM 卡'), findsOneWidget);
    expect(find.text('SIM 1 · 未读取运营商 · 卡槽 1'), findsNothing);
  });

  testWidgets(
    'forwarding page refreshes sim cards after permissions are granted',
    (WidgetTester tester) async {
      Map<String, Object?> snapshot = const {};
      final grantedSnapshot = {
        'permissions': {
          'receiveSms': true,
          'sendSms': true,
          'callPhone': true,
          'readPhoneState': true,
          'readPhoneNumbers': true,
        },
        'simCards': [
          {
            'subscriptionId': 7,
            'slotIndex': 0,
            'displayName': '工作卡',
            'carrierName': '中国移动',
            'number': '+8613800138000',
          },
        ],
      };

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('doppel/platform'), (
            MethodCall call,
          ) async {
            switch (call.method) {
              case 'getSnapshot':
                return snapshot;
              case 'requestRequiredPermissions':
                snapshot = grantedSnapshot;
                return true;
              case 'saveConfig':
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('doppel/platform'),
              null,
            );
      });
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const DoppelApp(autoRequestPermissionsOnStart: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('系统设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('申请授权'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('转发').last);
      await tester.pumpAndSettle();

      expect(find.text('工作卡 · +8613800138000'), findsOneWidget);
      expect(find.text('未读取到 SIM 卡'), findsNothing);
    },
  );
}
