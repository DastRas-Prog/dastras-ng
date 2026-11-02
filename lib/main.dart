import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home.dart';
import 'lang.dart';
import 'theme.dart';

const kAppName = 'DastRas NG';
const kChannelUrl = 'https://t.me/dastras';
const kChannelText = 't.me/dastras';
const kChannelUser = 'dastras';
const kSupportUser = 'xAdministrator';

Future<void> openUrl(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Opens the Telegram app directly (no browser); falls back to the web link.
Future<void> openTelegram(String user) async {
  try {
    final ok = await launchUrl(
      Uri.parse('tg://resolve?domain=$user'),
      mode: LaunchMode.externalApplication,
    );
    if (ok) return;
  } catch (_) {}
  await openUrl('https://t.me/$user');
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langN,
      builder: (context, code, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        locale: Locale(code),
        supportedLocales: const [Locale('fa'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: kAccent,
          scaffoldBackgroundColor: kBg0,
        ),
        home: const Gate(),
      ),
    );
  }
}

/// loading -> language (first run only) -> welcome (channel) -> home
class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  int stage = 0; // 0 loading, 1 language, 2 welcome, 3 home
  bool first = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString('lang');
    if (saved == null) {
      first = true;
      setState(() => stage = 1);
    } else {
      langN.value = saved;
      setState(() => stage = 2);
      Future.delayed(const Duration(milliseconds: 2400), () {
        if (mounted && stage == 2) setState(() => stage = 3);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget page;
    switch (stage) {
      case 1:
        page = LanguagePage(
          key: const ValueKey('lang'),
          onPick: (code) async {
            await saveLang(code);
            if (mounted) setState(() => stage = 2);
          },
        );
        break;
      case 2:
        page = WelcomePage(key: const ValueKey('welcome'), onContinue: () => setState(() => stage = 3));
        break;
      case 3:
        page = const Home(key: ValueKey('home'));
        break;
      default:
        page = const Backdrop(key: ValueKey('load'), child: SizedBox.expand());
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: page);
  }
}

class LanguagePage extends StatelessWidget {
  final void Function(String) onPick;
  const LanguagePage({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Backdrop(
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Logo(size: 110),
                const SizedBox(height: 18),
                const Text(kAppName, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
                const SizedBox(height: 36),
                const Text('انتخاب زبان', style: TextStyle(fontSize: 20)),
                const SizedBox(height: 4),
                const Text('Choose your language', style: TextStyle(fontSize: 16, color: Colors.white60)),
                const SizedBox(height: 24),
                _LangButton(label: 'فارسی', onTap: () => onPick('fa')),
                const SizedBox(height: 12),
                _LangButton(label: 'English', onTap: () => onPick('en')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _LangButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 56,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: kGlass,
          side: const BorderSide(color: kGlassBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontSize: 20, color: Colors.white)),
      ),
    );
  }
}

class WelcomePage extends StatelessWidget {
  final VoidCallback onContinue;
  const WelcomePage({super.key, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    return Tr((context) => Scaffold(
          body: Backdrop(
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Logo(size: 120),
                    const SizedBox(height: 18),
                    const Text(kAppName, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 30),
                    Text(tr('welcome_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(tr('welcome_sub'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, color: Colors.white60)),
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: kGlass,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: kGlassBorder),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.send_rounded, color: kCyan),
                        const SizedBox(width: 12),
                        const Directionality(
                          textDirection: TextDirection.ltr,
                          child: Text(kChannelText, style: TextStyle(fontSize: 20, letterSpacing: 0.5)),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: tr('copy'),
                          icon: const Icon(Icons.copy_rounded, size: 20),
                          onPressed: () async {
                            await Clipboard.setData(const ClipboardData(text: kChannelUrl));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(SnackBar(content: Text(tr('copied'))));
                            }
                          },
                        ),
                      ]),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: 260,
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: () => openTelegram(kChannelUser),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: Text(tr('open_channel')),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 260,
                      height: 52,
                      child: FilledButton(
                        onPressed: onContinue,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text(tr('continue'), style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ));
  }
}
