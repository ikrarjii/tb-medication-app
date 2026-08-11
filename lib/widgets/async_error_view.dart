import 'package:flutter/material.dart';

class AsyncErrorView extends StatelessWidget {
  const AsyncErrorView({super.key, required this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  String get _message {
    final value = error.toString().toLowerCase();
    if (value.contains('permission-denied') ||
        value.contains('insufficient permissions')) {
      return 'Akses data ditolak. Pastikan akun Anda memiliki akses dan '
          'aturan keamanan Firestore terbaru sudah diterapkan.';
    }
    if (value.contains('unavailable') || value.contains('network')) {
      return 'Koneksi ke server terputus. Periksa internet Anda lalu coba lagi.';
    }
    return 'Terjadi kendala saat memuat data. Silakan coba beberapa saat lagi.';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          margin: const EdgeInsets.all(20),
          color: colors.errorContainer.withValues(alpha: .55),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: colors.error.withValues(alpha: .12),
                  child: Icon(
                    Icons.cloud_off_rounded,
                    color: colors.error,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Data belum dapat dimuat',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Coba lagi'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
