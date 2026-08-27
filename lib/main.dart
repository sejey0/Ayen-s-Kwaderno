import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/user_profile_model.dart';
import 'screens/home_screen.dart';
import 'screens/select_profile_screen.dart';
import 'screens/welcome_auth_screen.dart';
import 'services/auto_sync_service.dart';
import 'services/user_service.dart';
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

  // Load environment variables from .env file
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint('Dotenv load notice: $e');
  }

  // Read Supabase credentials from dotenv
  final supabaseUrl = dotenv.env['SUPABASE_URL'] ??
      'https://cncvlmpysgueyrwgkupm.supabase.co';
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  // Initialize Supabase with credentials
  try {
    await Supabase.initialize(
      url: supabaseUrl,
      // ignore: deprecated_member_use
      anonKey: supabaseAnonKey,
    );
  } catch (e) {
    debugPrint('Supabase initialization error: $e');
  }

  // Initialize User Profile service (offline accounts + cloud auth)
  await UserService.instance.init();

  // Initialize automated background sync & connectivity monitoring
  AutoSyncService.instance.initialize();

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
      home: ValueListenableBuilder<UserProfile?>(
        valueListenable: UserService.instance.currentUserNotifier,
        builder: (context, user, _) {
          if (user == null) {
            return ValueListenableBuilder<List<UserProfile>>(
              valueListenable: UserService.instance.profilesListNotifier,
              builder: (context, profiles, _) {
                if (profiles.isNotEmpty) {
                  return const SelectProfileScreen();
                }
                return const WelcomeAuthScreen();
              },
            );
          }
          return const HomeScreen();
        },
      ),
    );
  }
}
