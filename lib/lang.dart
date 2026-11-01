import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

final ValueNotifier<String> langN = ValueNotifier<String>('fa');

bool get isFa => langN.value == 'fa';

Future<void> saveLang(String code) async {
  langN.value = code;
  final p = await SharedPreferences.getInstance();
  await p.setString('lang', code);
}

String tr(String k) => (isFa ? _fa : _en)[k] ?? k;

/// Rebuilds its child whenever the language changes.
class Tr extends StatelessWidget {
  final Widget Function(BuildContext) builder;
  const Tr(this.builder, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: langN,
        builder: (c, _, __) => builder(c),
      );
}

const _fa = {
  'choose_lang': 'انتخاب زبان',
  'choose_lang_sub': 'Choose your language',
  'continue': 'ادامه',
  'welcome_title': 'به کانال ما بپیوندید',
  'welcome_sub': 'بهترین نرم‌افزارهای به‌روز و پولی، رایگان در کانال',
  'open_channel': 'باز کردن کانال',
  'copy': 'کپی',
  'copied': 'کپی شد',
  'tap_connect': 'برای اتصال لمس کنید',
  'connected': 'متصل شد',
  'connecting': 'در حال اتصال...',
  'updating_sub': 'به‌روزرسانی اشتراک...',
  'add_config': 'افزودن کانفیگ',
  'add_hint': 'لینک ساب یا لینک‌های vless / vmess / trojan / ss',
  'paste': 'چسباندن',
  'cancel': 'انصراف',
  'add': 'افزودن',
  'subscription': 'اشتراک',
  'update_sub': 'به‌روزرسانی ساب',
  'test_ping': 'تست تأخیر',
  'delete_all': 'حذف همه کانفیگ‌ها و ساب‌ها',
  'no_config': 'هنوز کانفیگی اضافه نشده.\nبا دکمه‌ی + لینک ساب یا کانفیگ اضافه کنید.',
  'need_config': 'ابتدا یک کانفیگ یا ساب اضافه کنید',
  'disconnect_first': 'برای تست تأخیر ابتدا اتصال را قطع کنید',
  'no_sub': 'ساب اضافه نشده',
  'sub_updated': 'ساب به‌روز شد',
  'configs_n': 'کانفیگ',
  'added_n': 'کانفیگ اضافه شد',
  'error': 'خطا',
  'vpn_denied': 'دسترسی VPN داده نشد',
  'settings': 'تنظیمات',
  'language': 'زبان',
  'bypass_iran': 'عبور مستقیم سایت‌ها و IPهای ایرانی',
  'support': 'پشتیبانی',
  'channel': 'کانال تلگرام',
  'about': 'درباره',
  'about_text': 'کلاینت مبتنی بر هسته‌ی Xray\nبرای اخبار و پشتیبانی به کانال و ادمین سر بزنید.',
  'delete': 'حذف',
  'expires': 'انقضا',
  'per_app': 'پروکسی برنامه‌ها',
  'per_app_all': 'همه',
  'per_app_include': 'فقط انتخاب‌شده‌ها',
  'per_app_exclude': 'به‌جز انتخاب‌شده‌ها',
  'per_app_note_include': 'اگر هیچ برنامه‌ای انتخاب نکنید، همه‌ی برنامه‌ها از VPN استفاده می‌کنند.',
  'per_app_note_all': 'برای انتخاب برنامه، یکی از دو حالت دیگر را بزنید.',
  'search': 'جستجو',
  'apps_selected': 'انتخاب‌شده',
  'ping_note': 'تست تأخیر فقط در حالت قطع کار می‌کند',
  'no_servers': 'سروری انتخاب نشده',
};

const _en = {
  'choose_lang': 'Choose language',
  'choose_lang_sub': 'انتخاب زبان',
  'continue': 'Continue',
  'welcome_title': 'Join our channel',
  'welcome_sub': 'The best up-to-date premium apps, free, in our channel',
  'open_channel': 'Open channel',
  'copy': 'Copy',
  'copied': 'Copied',
  'tap_connect': 'Tap to connect',
  'connected': 'Connected',
  'connecting': 'Connecting...',
  'updating_sub': 'Updating subscription...',
  'add_config': 'Add config',
  'add_hint': 'Subscription link or vless / vmess / trojan / ss links',
  'paste': 'Paste',
  'cancel': 'Cancel',
  'add': 'Add',
  'subscription': 'Subscription',
  'update_sub': 'Update subscription',
  'test_ping': 'Test latency',
  'delete_all': 'Delete all configs and subscriptions',
  'no_config': 'No configs yet.\nTap + to add a subscription link or config.',
  'need_config': 'Add a config or subscription first',
  'disconnect_first': 'Disconnect first to test latency',
  'no_sub': 'No subscription added',
  'sub_updated': 'Subscription updated',
  'configs_n': 'configs',
  'added_n': 'configs added',
  'error': 'Error',
  'vpn_denied': 'VPN permission denied',
  'settings': 'Settings',
  'language': 'Language',
  'bypass_iran': 'Bypass Iranian sites and IPs',
  'support': 'Support',
  'channel': 'Telegram channel',
  'about': 'About',
  'about_text': 'A client built on the Xray core.\nVisit the channel and admin for news and support.',
  'delete': 'Delete',
  'expires': 'Expires',
  'per_app': 'Per-app proxy',
  'per_app_all': 'All apps',
  'per_app_include': 'Only selected',
  'per_app_exclude': 'All except selected',
  'per_app_note_include': 'If you select no apps, all apps will use the VPN.',
  'per_app_note_all': 'Pick one of the other two modes to choose apps.',
  'search': 'Search',
  'apps_selected': 'selected',
  'ping_note': 'Latency test works only while disconnected',
  'no_servers': 'No server selected',
};
