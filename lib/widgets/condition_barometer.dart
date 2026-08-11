import 'package:flutter/material.dart';

class ConditionBarometer extends StatelessWidget {
  const ConditionBarometer({
    super.key,
    required this.condition,
    this.compact = false,
  });

  final String condition;
  final bool compact;

  int get _level => switch (condition.toLowerCase()) {
    'high' => 2,
    'moderate' => 1,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF2A9D79),
      const Color(0xFFE9A23B),
      const Color(0xFFD95852),
    ];
    final labels = ['Ringan', 'Sedang', 'Tinggi'];
    return Semantics(
      label: 'Status kesehatan tercatat: ${labels[_level]}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) ...[
            Row(
              children: [
                const Icon(Icons.monitor_heart_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Kondisi tercatat',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  labels[_level],
                  style: TextStyle(
                    color: colors[_level],
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: List.generate(3, (index) {
              final selected = index == _level;
              return Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: compact ? 7 : 10,
                  margin: EdgeInsets.only(right: index == 2 ? 0 : 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors[index]
                        : colors[index].withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              );
            }),
          ),
          if (!compact) ...[
            const SizedBox(height: 8),
            Text(
              'Status ini dicatat oleh tim perawatan dan bukan merupakan diagnosis.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
