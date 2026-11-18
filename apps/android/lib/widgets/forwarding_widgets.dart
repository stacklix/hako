import 'package:flutter/material.dart';

import '../models/app_models.dart';
import 'common_widgets.dart';

class ForwardTargetTab extends StatelessWidget {
  const ForwardTargetTab({
    super.key,
    required this.title,
    required this.targets,
    required this.emptyText,
    required this.addLabel,
    required this.onDelete,
    required this.onAdd,
    this.badge,
    this.header,
    this.footer,
  });

  final String title;
  final List<ForwardTarget> targets;
  final String emptyText;
  final String addLabel;
  final ValueChanged<ForwardTarget> onDelete;
  final VoidCallback onAdd;
  final Widget? badge;
  final Widget? header;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        if (header != null) ...[header!, const SizedBox(height: 12)],
        SectionCard(
          title: title,
          badge: badge,
          child: Column(
            children: [
              EditableTargetList(
                targets: targets,
                emptyText: emptyText,
                onDelete: onDelete,
              ),
              AddConfigButton(label: addLabel, onPressed: onAdd),
            ],
          ),
        ),
        if (footer != null) ...[
          const SizedBox(height: 12),
          SectionCard(title: 'HTTP 载荷', child: footer!),
        ],
      ],
    );
  }
}

class SmtpSettingsCard extends StatelessWidget {
  const SmtpSettingsCard({
    super.key,
    required this.settings,
    required this.onConfigure,
  });

  final SmtpSettings? settings;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final current = settings;
    return SectionCard(
      title: 'SMTP 发件人',
      badge: StatusBadge(
        text: current == null ? '未配置' : '已配置',
        tone: current == null ? BadgeTone.warning : BadgeTone.success,
      ),
      child: Column(
        children: [
          SummaryRow(
            icon: Icons.outgoing_mail,
            title: current?.fromEmail ?? '未配置发件邮箱',
            subtitle: current == null
                ? '配置 SMTP 后才能自动转发到邮箱'
                : '${current.host}:${current.effectivePort}',
            trailing: current == null
                ? null
                : IconButton(
                    tooltip: '编辑发件人',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onConfigure,
                  ),
          ),
          if (current == null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.settings_outlined),
                label: const Text('配置发件人'),
                onPressed: onConfigure,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class SimSelectorCard extends StatelessWidget {
  const SimSelectorCard({
    super.key,
    required this.selectedSim,
    required this.simLabels,
    required this.onChanged,
  });

  final String? selectedSim;
  final List<String> simLabels;
  final ValueChanged<String?> onChanged;

  Future<void> _showSimPickerDialog(
    BuildContext context,
    String currentLabel,
  ) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('选择短信发送卡'),
          content: SizedBox(
            width: 360,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: simLabels.length,
              itemBuilder: (context, index) {
                final label = simLabels[index];
                final selected = label == currentLabel;
                return ListTile(
                  title: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: selected
                      ? const Icon(Icons.check, color: Color(0xFF0F766E))
                      : null,
                  onTap: () {
                    Navigator.of(dialogContext).pop(label);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    if (picked != null && picked != currentLabel) {
      onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasMultipleSims = simLabels.length > 1;
    final currentLabel = simLabels.contains(selectedSim)
        ? selectedSim!
        : simLabels.isEmpty
        ? null
        : simLabels.first;

    return SectionCard(
      title: '短信发送卡',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (simLabels.isEmpty)
            const EmptyState(
              icon: Icons.sim_card_alert_outlined,
              title: '未读取到 SIM 卡',
              subtitle: '授权读取电话状态后会显示卡槽、运营商、卡名和号码',
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sim_card,
                    size: 18,
                    color: Color(0xFF0F766E),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      currentLabel ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (hasMultipleSims && currentLabel != null) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '选择短信发送卡',
                      child: TextButton.icon(
                        onPressed: () =>
                            _showSimPickerDialog(context, currentLabel),
                        icon: const Icon(Icons.sync_alt, size: 16),
                        label: const Text('切换'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class EditableTargetList extends StatelessWidget {
  const EditableTargetList({
    super.key,
    required this.targets,
    required this.emptyText,
    required this.onDelete,
  });

  final List<ForwardTarget> targets;
  final String emptyText;
  final ValueChanged<ForwardTarget> onDelete;

  @override
  Widget build(BuildContext context) {
    if (targets.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            emptyText,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Column(
      children: targets.map((target) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFEAF0F5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      target.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '删除 ${target.value}',
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      color: const Color(0xFFB91C1C),
                      onPressed: () => onDelete(target),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class AddConfigButton extends StatelessWidget {
  const AddConfigButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.add),
        label: Text(label),
        onPressed: onPressed,
      ),
    );
  }
}
