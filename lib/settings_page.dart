import 'package:flutter/material.dart';

import 'apps_page.dart';
import 'config.dart';
import 'core.dart';
import 'lang.dart';
import 'main.dart' show kAppName, kChannelUser, kChannelText, kSupportUser, openTelegram;
import 'models.dart';
import 'service.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  final Store store;
  const SettingsPage({super.key, required this.store});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Store get s => widget.store;

  Future<void> _set(VoidCallback f) async {
    setState(f);
    await s.save();
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Text(title, style: const TextStyle(fontSize: 14, color: kCyan, fontWeight: FontWeight.w600)),
        ),
        Container(
          decoration: BoxDecoration(
            color: kGlass,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kGlassBorder),
          ),
          child: Column(children: children),
        ),
      ]),
    );
  }

  Widget _switch(String title, bool v, void Function(bool) f, {String? sub, IconData? icon}) {
    return SwitchListTile(
      secondary: icon == null ? null : Icon(icon, color: kCyan),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
      value: v,
      onChanged: (x) => _set(() => f(x)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) => Scaffold(
          body: Backdrop(
            child: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(children: [
                    IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
                    Text(tr('settings'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                  ]),
                ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
                    _section(tr('sec_general'), [
                      ListTile(
                        leading: const Icon(Icons.language_rounded, color: kCyan),
                        title: Text(tr('language')),
                        trailing: SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: 'fa', label: Text('فارسی')),
                            ButtonSegment(value: 'en', label: Text('EN')),
                          ],
                          selected: {langN.value},
                          onSelectionChanged: (v) async {
                            await saveLang(v.first);
                            setState(() {});
                          },
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.apps_rounded, color: kCyan),
                        title: Text(tr('per_app')),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => AppsPage(store: s)),
                        ),
                      ),
                    ]),
                    _section(tr('sec_auto'), [
                      _switch(tr('opt_auto_select'), s.autoSelect, (v) => s.autoSelect = v,
                          sub: tr('opt_auto_select_sub'), icon: Icons.auto_awesome_rounded),
                      _switch(tr('opt_auto_update'), s.autoUpdate, (v) => s.autoUpdate = v, icon: Icons.sync_rounded),
                      _switch(tr('opt_connect_open'), s.connectOnOpen, (v) => s.connectOnOpen = v,
                          icon: Icons.bolt_rounded),
                      _switch(tr('opt_clipboard'), s.clipboardWatch, (v) => s.clipboardWatch = v,
                          icon: Icons.content_paste_rounded),
                    ]),
                    _section(tr('sec_test'), [
                      ListTile(
                        leading: const Icon(Icons.speed_rounded, color: kCyan),
                        title: Text(tr('opt_ping_mode')),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'tcp', label: Text(tr('ping_tcp'))),
                                ButtonSegment(value: 'real', label: Text(tr('ping_real'))),
                              ],
                              selected: {s.pingMode},
                              onSelectionChanged: (v) => _set(() => s.pingMode = v.first),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(tr('ping_tcp_note'),
                            style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.link_rounded, color: kCyan),
                        title: Text(tr('opt_test_url')),
                        trailing: DropdownButton<String>(
                          value: kTestUrls.containsKey(s.testUrl) ? s.testUrl : kTestUrls.keys.first,
                          underline: const SizedBox(),
                          items: [
                            for (final e in kTestUrls.entries)
                              DropdownMenuItem(value: e.key, child: Text(e.value)),
                          ],
                          onChanged: (v) {
                            if (v != null) _set(() => s.testUrl = v);
                          },
                        ),
                      ),
                    ]),
                    _section(tr('sec_network'), [
                      _switch(tr('bypass_iran'), s.bypassIran, (v) => s.bypassIran = v,
                          icon: Icons.shield_moon_rounded),
                      _switch(tr('opt_fragment'), s.fragment, (v) => s.fragment = v, icon: Icons.content_cut_rounded),
                      _switch(tr('opt_mux'), s.mux, (v) => s.mux = v, icon: Icons.merge_type_rounded),
                      _switch(tr('opt_ipv6'), s.ipv6, (v) => s.ipv6 = v, icon: Icons.public_rounded),
                      _switch(tr('opt_ads'), s.blockAds, (v) => s.blockAds = v, icon: Icons.block_rounded),
                      ListTile(
                        leading: const Icon(Icons.dns_rounded, color: kCyan),
                        title: Text(tr('opt_dns')),
                        trailing: DropdownButton<String>(
                          value: kDns.containsKey(s.dns) ? s.dns : 'cloudflare',
                          underline: const SizedBox(),
                          items: [
                            for (final e in kDnsNames.entries)
                              DropdownMenuItem(value: e.key, child: Text(e.value)),
                          ],
                          onChanged: (v) {
                            if (v != null) _set(() => s.dns = v);
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Text(tr('apply_next'),
                            style: const TextStyle(fontSize: 12.5, color: Colors.white38)),
                      ),
                    ]),
                    _section(tr('sec_security'), [
                      _switch(tr('opt_https_only'), s.httpsOnly, (v) => s.httpsOnly = v, icon: Icons.lock_rounded),
                      ListTile(
                        leading: const Icon(Icons.vpn_lock_rounded, color: kCyan),
                        title: Text(tr('sys_vpn')),
                        trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                        onTap: () => Core.vpnSettings(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(tr('sec_note'),
                            style: const TextStyle(fontSize: 12.5, color: Colors.white54)),
                      ),
                    ]),
                    _section(tr('sec_support'), [
                      ListTile(
                        leading: const Icon(Icons.support_agent_rounded, color: kCyan),
                        title: Text(tr('support')),
                        subtitle: const Text('@$kSupportUser'),
                        onTap: () => openTelegram(kSupportUser),
                      ),
                      ListTile(
                        leading: const Icon(Icons.send_rounded, color: kCyan),
                        title: Text(tr('channel')),
                        subtitle: const Text(kChannelText),
                        onTap: () => openTelegram(kChannelUser),
                      ),
                      ListTile(
                        leading: const Icon(Icons.info_outline_rounded, color: kCyan),
                        title: Text(tr('about')),
                        subtitle: Text(tr('about_text')),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Center(child: Text(kAppName, style: TextStyle(color: Colors.white38))),
                      ),
                    ]),
                  ]),
                ),
              ]),
            ),
          ),
        ));
  }
}
