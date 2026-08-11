import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'screens/caregiver_home_screen.dart';
import 'screens/patient_home_screen.dart';
import 'services/auth_service.dart';
import 'services/medicine_repository.dart';
import 'services/push_notification_service.dart';
import 'services/reminder_service.dart';
import 'services/treatment_monitoring_repository.dart';
import 'wrapper.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
  );
  await ReminderService.instance.initialize();
  runApp(const MedicineControlApp());
}

class MedicineControlApp extends StatelessWidget {
  const MedicineControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        Provider(create: (_) => MedicineRepository()),
        Provider(create: (_) => TreatmentMonitoringRepository()),
      ],
      child: MaterialApp(
        title: 'Kontrol Obat',
        debugShowCheckedModeBanner: false,
        locale: const Locale('id', 'ID'),
        supportedLocales: const [Locale('id', 'ID')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF07866F),
            brightness: Brightness.light,
            surface: const Color(0xFFFFFFFF),
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF4F9F7),
          fontFamily: 'Roboto',
          textTheme: const TextTheme(
            headlineSmall: TextStyle(
              color: Color(0xFF153C35),
              letterSpacing: -.4,
            ),
            titleLarge: TextStyle(color: Color(0xFF153C35)),
            titleMedium: TextStyle(color: Color(0xFF153C35)),
            bodyLarge: TextStyle(color: Color(0xFF34554F)),
            bodyMedium: TextStyle(color: Color(0xFF48655F)),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF7FBFA),
            labelStyle: const TextStyle(color: Color(0xFF54736D)),
            prefixIconColor: const Color(0xFF07866F),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFD9E9E4)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFD9E9E4)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFF07866F), width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 17,
            ),
          ),
          cardTheme: CardThemeData(
            elevation: 1.5,
            shadowColor: const Color(0xFF123E35).withValues(alpha: .10),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: const BorderSide(color: Color(0xFFE1EDE9)),
            ),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF4F9F7),
            surfaceTintColor: Colors.transparent,
            centerTitle: false,
            elevation: 0,
            titleTextStyle: TextStyle(
              color: Color(0xFF153C35),
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
          navigationBarTheme: NavigationBarThemeData(
            height: 72,
            backgroundColor: Colors.white,
            indicatorColor: const Color(0xFFD8F2E9),
            elevation: 8,
            shadowColor: const Color(0x1A17483E),
            labelTextStyle: WidgetStateProperty.all(
              const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              backgroundColor: const Color(0xFF07866F),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              foregroundColor: const Color(0xFF087863),
              side: const BorderSide(color: Color(0xFF9CCFC0)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: const Color(0xFFE8F6F1),
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            labelStyle: const TextStyle(
              color: Color(0xFF176B5A),
              fontWeight: FontWeight.w700,
            ),
          ),
          snackBarTheme: SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF173F37),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        home: const Wrapper(),
        routes: {
          '/patient-home': (_) => const PatientHomeScreen(),
          '/caregiver-home': (_) => const CaregiverHomeScreen(),
        },
      ),
    );
  }
}
