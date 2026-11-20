import 'package:nami/models/app_models.dart';
import 'package:nami/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('doppel/platform');
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          permissions: const PlatformPermissions(),
          onSnapshotChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('system shortcuts invoke only their intended native targets', (
    tester,
  ) async {
    final opened = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSystemSettings') {
            return {
              'autoStartAvailable': true,
              'backgroundAvailable': true,
              'batteryExempt': false,
              'notificationsEnabled': true,
            };
          }
          if (call.method == 'openSystemSettings') {
            opened.add((call.arguments as Map)['target'] as String);
          }
          return null;
        });
    await pumpSettings(tester);
    for (final title in ['开机自启动', '后台省电策略', '电池优化', '通知设置', '应用权限与详情']) {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }
    expect(opened, [
      'autoStart',
      'background',
      'battery',
      'notifications',
      'application',
    ]);
    expect(find.text('已开启自启动'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets(
    'unsupported OEM shortcuts are disabled and explain where to look',
    (tester) async {
      var opened = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getSystemSettings') return <String, Object?>{};
            if (call.method == 'openSystemSettings') opened = true;
            return null;
          });
      await pumpSettings(tester);
      final row = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '开机自启动'),
      );
      expect(row.enabled, isFalse);
      expect(row.onTap, isNull);
      expect(find.text('此系统未提供快捷入口，请在应用详情中查找'), findsNWidgets(2));
      expect(opened, isFalse);
    },
  );

  testWidgets('returning from system settings refreshes real status', (
    tester,
  ) async {
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSystemSettings') {
            reads++;
            return {
              'autoStartAvailable': true,
              'backgroundAvailable': true,
              'batteryExempt': reads > 1,
              'notificationsEnabled': reads > 1,
            };
          }
          if (call.method == 'getSnapshot') return <String, Object?>{};
          return null;
        });
    await pumpSettings(tester);
    expect(find.text('通知未允许，点击前往设置'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('已忽略电池优化'), findsOneWidget);
    expect(find.text('通知已允许'), findsOneWidget);
  });

  testWidgets(
    'Wi-Fi authorization is separate and background access is opt-in',
    (tester) async {
      var requests = 0;
      var requiredRequests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getSystemSettings') return <String, Object?>{};
            if (call.method == 'getWifiPermissions') {
              return {
                'preciseLocationGranted': requests > 0,
                'backgroundLocationGranted': requests > 1,
                'locationEnabled': true,
              };
            }
            if (call.method == 'requestWifiPermissions') requests++;
            if (call.method == 'requestRequiredPermissions') requiredRequests++;
            return null;
          });
      await pumpSettings(tester);
      expect(requests, 0);
      await tester.scrollUntilVisible(
        find.text('授权读取 Wi-Fi 名称'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('授权读取 Wi-Fi 名称'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权读取 Wi-Fi 名称'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.tap(find.text('Wi-Fi 名称权限设置'));
      await tester.pumpAndSettle();
      expect(find.text('后台读取 Wi-Fi 名称'), findsOneWidget);
      expect(requests, 1);
      await tester.tap(find.text('暂不授权'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.tap(find.text('Wi-Fi 名称权限设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('前往设置'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(requiredRequests, 0);
    },
  );

  testWidgets('opening a blocked settings page surfaces the system error', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getSystemSettings') {
            return {'autoStartAvailable': true};
          }
          if (call.method == 'openSystemSettings') {
            throw PlatformException(
              code: 'settings_unavailable',
              message: '系统不允许直接打开此页面',
            );
          }
          return null;
        });
    await pumpSettings(tester);
    await tester.tap(find.text('开机自启动'));
    await tester.pumpAndSettle();
    expect(find.text('系统不允许直接打开此页面'), findsOneWidget);
  });
}
