import 'dart:async';

import 'package:flutter/material.dart';

import 'models/app_models.dart';
import 'pages/commands_page.dart';
import 'pages/forwarding_page.dart';
import 'pages/logs_page.dart';
import 'pages/overview_page.dart';
import 'pages/settings_page.dart';
import 'platform/nami_platform.dart';

class NamiApp extends StatelessWidget {
  const NamiApp({super.key, this.autoRequestPermissionsOnStart = true});

  final bool autoRequestPermissionsOnStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nami',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        fontFamily: 'Roboto',
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        ),
      ),
      home: NamiHome(
        autoRequestPermissionsOnStart: autoRequestPermissionsOnStart,
      ),
    );
  }
}

class NamiHome extends StatefulWidget {
  const NamiHome({super.key, this.autoRequestPermissionsOnStart = true});

  final bool autoRequestPermissionsOnStart;

  @override
  State<NamiHome> createState() => _NamiHomeState();
}

class _NamiHomeState extends State<NamiHome> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  List<LogEvent> _events = [];
  List<SimCardInfo> _simCards = [];
  PlatformPermissions _permissions = const PlatformPermissions();
  AppConfig _config = const AppConfig();
  RemoteControlStatus _remoteControlStatus = const RemoteControlStatus();
  bool _hasRequiredPermissions = false;
  bool _permissionPromptHandled = false;
  bool _isLoadingSnapshot = false;
  Timer? _snapshotRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NamiPlatform.setSnapshotListener((snapshot) {
      if (!mounted) {
        return;
      }
      setState(() {
        _applyPlatformSnapshot(snapshot);
      });
    });
    _loadPlatformSnapshot();
    _snapshotRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _loadPlatformSnapshot();
    });
  }

  @override
  void dispose() {
    _snapshotRefreshTimer?.cancel();
    NamiPlatform.clearSnapshotListener();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPlatformSnapshot();
    }
  }

  Future<void> _loadPlatformSnapshot() async {
    if (_isLoadingSnapshot) {
      return;
    }
    _isLoadingSnapshot = true;
    try {
      final snapshot = await NamiPlatform.getSnapshot();
      if (mounted) {
        setState(() {
          _applyPlatformSnapshot(snapshot);
        });

        await _maybeRequestRequiredPermissions(snapshot);
      }
    } finally {
      _isLoadingSnapshot = false;
    }
  }

  Future<void> _maybeRequestRequiredPermissions(
    PlatformSnapshot snapshot,
  ) async {
    if (!widget.autoRequestPermissionsOnStart || _permissionPromptHandled) {
      return;
    }
    if (snapshot.hasRequiredPermissions) {
      _permissionPromptHandled = true;
      return;
    }

    _permissionPromptHandled = true;
    final shouldRequest = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('需要权限以开始工作'),
          content: const Text('Nami 需要短信、电话和电话状态权限，用于接收短信、识别指令和转发通知。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('稍后处理'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('立即授权'),
            ),
          ],
        );
      },
    );

    if (shouldRequest != true) {
      return;
    }

    await NamiPlatform.requestRequiredPermissions();
    final refreshedSnapshot = await NamiPlatform.getSnapshot();
    if (!mounted) {
      return;
    }
    setState(() {
      _applyPlatformSnapshot(refreshedSnapshot);
    });
  }

  void _applyPlatformSnapshot(PlatformSnapshot snapshot) {
    _events = snapshot.events;
    _simCards = snapshot.simCards;
    _permissions = snapshot.permissions;
    _config = snapshot.config;
    _remoteControlStatus = snapshot.remoteControlStatus;
    _hasRequiredPermissions = snapshot.hasRequiredPermissions;
  }

  List<AppMetric> get _metrics {
    return [
      AppMetric(
        title: '短信事件',
        todayLabel: '今日短信事件',
        totalLabel: '累计短信事件',
        todayValue: _todayCountByTypes(const ['sms_received', 'sms_command']),
        totalValue: _totalCountByTypes(const ['sms_received', 'sms_command']),
        helpText: '今天收到的全部短信数量，包含普通短信和短信指令。',
      ),
      AppMetric(
        title: '来电事件',
        todayLabel: '今日来电事件',
        totalLabel: '累计来电事件',
        todayValue: _todayCount('call_received'),
        totalValue: _totalCount('call_received'),
        helpText: '今天记录到的来电数量。',
      ),
      AppMetric(
        title: '转发短信',
        todayLabel: '今日转发短信',
        totalLabel: '累计转发短信',
        todayValue: _todayCount('sms_forwarded'),
        totalValue: _totalCount('sms_forwarded'),
        helpText: '今天成功转发出去的短信数量。',
      ),
      AppMetric(
        title: '短信指令',
        todayLabel: '今日短信指令',
        totalLabel: '累计短信指令',
        todayValue: _todayCount('sms_command'),
        totalValue: _totalCount('sms_command'),
        helpText: '今天由白名单号码触发并识别的短信指令数量。',
      ),
    ];
  }

  String _todayCount(String type) {
    final now = DateTime.now();
    final count = _events.where((event) {
      final timestamp = event.localTimestamp;
      return event.type == type &&
          timestamp.year == now.year &&
          timestamp.month == now.month &&
          timestamp.day == now.day;
    }).length;
    return count.toString();
  }

  String _totalCount(String type) {
    return _events.where((event) => event.type == type).length.toString();
  }

  String _todayCountByTypes(List<String> types) {
    final now = DateTime.now();
    final count = _events.where((event) {
      final timestamp = event.localTimestamp;
      return types.contains(event.type) &&
          timestamp.year == now.year &&
          timestamp.month == now.month &&
          timestamp.day == now.day;
    }).length;
    return count.toString();
  }

  String _totalCountByTypes(List<String> types) {
    return _events
        .where((event) => types.contains(event.type))
        .length
        .toString();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      OverviewPage(
        metrics: _metrics,
        events: _events,
        isRunning: _hasRequiredPermissions,
      ),
      ForwardingPage(
        simCards: _simCards,
        initialConfig: _config.forwarding,
      ),
      CommandsPage(
        initialConfig: _config.commands,
        remoteConfig: _config.remoteControl,
        remoteStatus: _remoteControlStatus,
      ),
      LogsPage(events: _events),
    ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nami',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 24),
            ),
            SizedBox(height: 2),
            Text(
              '短信转发与远程拨号助手',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '系统设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(
                    permissions: _permissions,
                    onSnapshotChanged: (snapshot) {
                      if (!mounted) {
                        return;
                      }
                      setState(() {
                        _applyPlatformSnapshot(snapshot);
                      });
                    },
                  ),
                ),
              );
              await _loadPlatformSnapshot();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _selectedIndex, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.sync_alt_outlined),
            selectedIcon: Icon(Icons.sync_alt),
            label: '转发',
          ),
          NavigationDestination(
            icon: Icon(Icons.check_box_outlined),
            selectedIcon: Icon(Icons.check_box),
            label: '指令',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: '日志',
          ),
        ],
      ),
    );
  }
}
