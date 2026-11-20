import 'package:nami/pages/agent_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('doppel/platform');
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'requires a registered key and saves explicit action permissions',
    (tester) async {
      var settings = <String, Object?>{
        'server': '',
        'username': '',
        'enabled': false,
        'allowSms': false,
        'allowCalls': false,
        'publicKey': '',
        'status': {'state': 'disconnected', 'message': '未连接'},
      };
      final saved = <Map<String, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'generateAgentKey') {
              settings = {
                ...settings,
                'publicKey': 'PUBLIC KEY',
                'keyId': 'fingerprint',
              };
            }
            if (call.method == 'saveAgentSettings') {
              final args = Map<String, Object?>.from(call.arguments as Map);
              saved.add(args);
              settings = {...settings, ...args};
            }
            return settings;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.binding.setSurfaceSize(const Size(420, 1500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(home: AgentSettingsPage()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'https://hako.example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'owner');
      await tester.tap(find.widgetWithText(SwitchListTile, '启用 Agent'));
      await tester.ensureVisible(find.text('保存并应用'));
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('请先生成设备密钥，并在 Sora 中登记公钥'), findsOneWidget);
      await tester.ensureVisible(find.text('生成设备密钥'));
      await tester.tap(find.text('生成设备密钥'));
      await tester.pumpAndSettle();
      expect(find.text('fingerprint'), findsOneWidget);
      await tester.ensureVisible(find.text('保存并应用'));
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      expect(saved.single, {
        'enabled': true,
        'server': 'https://hako.example.com',
        'username': 'owner',
        'allowSms': false,
        'allowCalls': false,
      });
      expect(saved.single.containsKey('publicKey'), isFalse);
      expect(find.text('Agent 配置已保存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('surfaces native save errors without reporting success', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'saveAgentSettings') {
            throw PlatformException(
              code: 'storage_failed',
              message: 'Agent 配置保存失败',
            );
          }
          return <String, Object?>{};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.binding.setSurfaceSize(const Size(420, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AgentSettingsPage()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存并应用'));
    await tester.tap(find.text('保存并应用'));
    await tester.pumpAndSettle();
    expect(find.text('Agent 配置保存失败'), findsOneWidget);
    expect(find.text('Agent 配置已保存'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
