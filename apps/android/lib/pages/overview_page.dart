import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/common_widgets.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({
    super.key,
    required this.metrics,
    required this.events,
    required this.isRunning,
  });

  final List<AppMetric> metrics;
  final List<LogEvent> events;
  final bool isRunning;

  static const Set<String> _visibleRecentEventTypes = {
    'sms_received',
    'sms_command',
    'sms_sent_command',
    'call_received',
    'call_out_command',
  };

  List<LogEvent> get recentEvents {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    return events.where((event) {
      return _visibleRecentEventTypes.contains(event.type) &&
          event.source != 'system_sms' &&
          event.timestamp.isAfter(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visibleEvents = recentEvents;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        SectionCard(
          title: '运行状态',
          badge: StatusBadge(
            text: isRunning ? '运行中' : '等待授权',
            tone: isRunning ? BadgeTone.success : BadgeTone.warning,
          ),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.35,
            children: metrics.map(MetricTile.new).toList(),
          ),
        ),
        const SizedBox(height: 10),
        SectionCard(
          title: '最近事件',
          badge: const StatusBadge(text: '1 天内'),
          child: visibleEvents.isEmpty
              ? const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '暂无事件',
                  subtitle: '收到短信、执行指令或来电后会显示在这里',
                )
              : Column(
                  children: visibleEvents
                      .map((event) => EventRow(event: event))
                      .toList(),
                ),
        ),
      ],
    );
  }
}
