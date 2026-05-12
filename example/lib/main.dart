import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:plausible_flutter/plausible_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Replace `domain` and `apiHost` with your own Plausible site before running.
  //
  // `domain`   — the site identifier in your Plausible dashboard.
  // `apiHost`  — `https://plausible.io` for Plausible Cloud, or the URL of
  //              your self-hosted Plausible instance.
  //
  // userAgent and defaultProps (app_version, platform, os_version, device_model)
  // are auto-detected via package_info_plus + device_info_plus.
  await Plausible.init(
    domain: 'yourapp.com',
    apiHost: 'https://plausible.io',
    enableAutoPageviews: true,
    enabled: true, // flip to !kDebugMode once you ship to prod
    debug: kDebugMode,
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'plausible_flutter example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      navigatorObservers: [Plausible.navigatorObserver],
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/details': (_) => const DetailsScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pushNamed('/details'),
              child: const Text('Open details (auto pageview)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final result = await Plausible.instance.trackEvent(
                  'demo_button_clicked',
                  props: {'screen': 'home'},
                );
                debugPrint('trackEvent returned: $result');
              },
              child: const Text('Track custom event'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Plausible.instance.flush(),
              child: const Text('Flush queued events'),
            ),
          ],
        ),
      ),
    );
  }
}

class DetailsScreen extends StatelessWidget {
  const DetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      body: const Center(child: Text('Pageview fired automatically')),
    );
  }
}
