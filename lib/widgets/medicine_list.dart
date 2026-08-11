import 'package:flutter/material.dart';

import '../models/medicine.dart';
import 'async_error_view.dart';
import 'app_state_view.dart';

class MedicineList extends StatelessWidget {
  const MedicineList({
    super.key,
    required this.stream,
    this.emptyMessage = 'Tidak ada obat yang menunggu.',
    this.shrinkWrap = false,
  });

  final Stream<List<Medicine>> stream;
  final String emptyMessage;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Medicine>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) return AsyncErrorView(error: snapshot.error);
        if (!snapshot.hasData) {
          return const AppLoadingView(message: 'Memuat daftar obat…');
        }

        final medicines = snapshot.data!;
        if (medicines.isEmpty) {
          return AppEmptyState(
            icon: Icons.medication_outlined,
            title: 'Belum ada jadwal obat',
            message: emptyMessage,
          );
        }

        return ListView.separated(
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.all(16),
          itemCount: medicines.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final medicine = medicines[index];
            return Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.medication)),
                title: Text(
                  medicine.displayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
                subtitle: Text(_details(context, medicine)),
                trailing: const Chip(label: Text('Menunggu')),
              ),
            );
          },
        );
      },
    );
  }

  String _details(BuildContext context, Medicine medicine) {
    final parts = <String>[
      if (medicine.dosage?.isNotEmpty ?? false) medicine.dosage!,
      if (medicine.scheduledAt != null)
        'Jadwal: ${MaterialLocalizations.of(context).formatMediumDate(medicine.scheduledAt!)}',
    ];
    return parts.isEmpty ? 'Menunggu untuk diminum' : parts.join(' • ');
  }
}
