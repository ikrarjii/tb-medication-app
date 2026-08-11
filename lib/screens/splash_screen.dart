import 'package:flutter/material.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.primary, colors.tertiary],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: colors.onPrimary,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Icon(
                  Icons.medication_liquid_rounded,
                  size: 62,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Kontrol Obat',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: colors.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Kesehatan Anda, selalu terjadwal',
                style: TextStyle(color: colors.onPrimary.withValues(alpha: .8)),
              ),
              const SizedBox(height: 40),
              CircularProgressIndicator(color: colors.onPrimary),
            ],
          ),
        ),
      ),
    );
  }
}
