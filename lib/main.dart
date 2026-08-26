import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set clean system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.background,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  // Initialize Supabase with your project credentials
  // Replace these placeholders with your actual Supabase URL & Anon Key
  try {
    await Supabase.initialize(
      url: 'https://YOUR_SUPABASE_PROJECT_ID.supabase.co',
      anonKey: 'YOUR_SUPABASE_ANON_KEY', // ignore: deprecated_member_use
    );
  } catch (e) {
    debugPrint('Supabase initialization notice: $e');
  }

  runApp(const AyensKwadernoApp());
}

class AyensKwadernoApp extends StatelessWidget {
  const AyensKwadernoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Ayen's Kwaderno",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const HomeScreen(),
    );
  }
}
