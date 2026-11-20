import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/common_widgets.dart';

class LogsPage extends StatelessWidget {
  const LogsPage({super.key, required this.events});

  final List<LogEvent> events;

  static const Set<String> _visibleLogTypes = {
    'sms_received',
    'sms_command',
    'sms_sent_command',
    'call_received',
    'call_out_command',
    'sms_forwarded',
    'operation_log',
    'agent_connection',
  };

  List<LogEvent> get visibleEvents {
    return events
        .where((event) => _visibleLogTypes.contains(event.type))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final logs = visibleEvents;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        SectionCard(
          title: '事件日志',
          badge: const StatusBadge(text: '最近'),
          child: logs.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: '暂无日志',
                  subtitle: '连接服务器或处理短信和来电后会写入日志',
                )
              : Column(
                  children: logs
                      .map((event) => EventRow(event: event))
                      .toList(),
                ),
        ),
      ],
    );
  }
}
