import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'apps_page.dart';
import 'config.dart';
import 'core.dart';
import 'lang.dart';
import 'main.dart' show kAppName, kChannelUser, kChannelText, kSupportUser, openTelegram;
import 'models.dart';
import 'pal.dart';
import 'service.dart';
import 'theme.dart';
import 'update.dart';
import 'win_core.dart';

class SettingsPage extends StatefulWidget {
  final Store store;
  final bool embedded;
  const SettingsPage({super.key, required this.store, this.embedded = false});
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
          child: Text(title, style: TextStyle(fontSize: 14, color: Pal.cyan, fontWeight: FontWeight.w700)),
        ),
        Container(
          decoration: BoxDecoration(
            color: Pal.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Pal.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ]),
    );
  }

  Widget _switch(String title, bool v, void Function(bool) f, {String? sub, IconData? icon}) {
    return SwitchListTile(
      secondary: icon == null ? null : Icon(icon, color: Pal.cyan),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub, style: TextStyle(fontSize: 12.5, color: Pal.t3)),
      value: v,
      onChanged: (x) => _set(() => f(x)),
    );
  }

  Widget _note(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(t, style: TextStyle(fontSize: 12.5, color: Pal.t3)),
      );

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      final content = Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(children: [
                    if (widget.embedded) const SizedBox(width: 16) else IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
                    Text(tr('settings'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1)),
                  ]),
                ),
                Expanded(
                  child: ListView(padding: EdgeInsets.only(bottom: widget.embedded ? 110 : 30), children: [
                    _section(tr('sec_general'), [
                      ListTile(
                        leading: Icon(Icons.language_rounded, color: Pal.cyan),
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
                        leading: Icon(Icons.palette_rounded, color: Pal.cyan),
                        title: Text(tr('theme')),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: [
                                ButtonSegment(value: 'dark', label: Text(tr('theme_dark')), icon: const Icon(Icons.dark_mode_rounded, size: 18)),
                                ButtonSegment(value: 'light', label: Text(tr('theme_light')), icon: const Icon(Icons.light_mode_rounded, size: 18)),
                                ButtonSegment(value: 'system', label: Text(tr('theme_system')), icon: const Icon(Icons.brightness_auto_rounded, size: 18)),
                              ],
                              selected: {themeN.value},
                              onSelectionChanged: (v) async {
                                await saveTheme(v.first);
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ),
                      if (!Platform.isWindows)
                      ListTile(
                        leading: Icon(Icons.apps_rounded, color: Pal.cyan),
                        title: Text(tr('per_app')),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AppsPage(store: s))),
                      ),
                    ]),
                    _section(tr('sec_auto'), [
                      _switch(tr('opt_auto_select'), s.autoSelect, (v) => s.autoSelect = v,
                          sub: tr('opt_auto_select_sub'), icon: Icons.auto_awesome_rounded),
                      _switch(tr('opt_auto_update'), s.autoUpdate, (v) => s.autoUpdate = v, icon: Icons.sync_rounded),
                      ListTile(
                        leading: Icon(Icons.schedule_rounded, color: Pal.cyan),
                        title: Text(tr('opt_update_every')),
                        trailing: DropdownButton<int>(
                          value: const [0, 30, 60, 180].contains(s.updateEveryMin) ? s.updateEveryMin : 180,
                          underline: const SizedBox(),
                          items: [
                            DropdownMenuItem(value: 0, child: Text(tr('every_off'))),
                            DropdownMenuItem(value: 30, child: Text(tr('every_30'))),
                            DropdownMenuItem(value: 60, child: Text(tr('every_60'))),
                            DropdownMenuItem(value: 180, child: Text(tr('every_180'))),
                          ],
                          onChanged: (v) {
                            if (v != null) _set(() => s.updateEveryMin = v);
                          },
                        ),
                      ),
                      _note(tr('update_every_note')),
                      _switch(tr('opt_connect_open'), s.connectOnOpen, (v) => s.connectOnOpen = v, icon: Icons.bolt_rounded),
                      _switch(tr('opt_clipboard'), s.clipboardWatch, (v) => s.clipboardWatch = v, icon: Icons.content_paste_rounded),
                      _switch(tr('opt_announce'), s.announceOn, (v) => s.announceOn = v,
                          sub: tr('opt_announce_sub'), icon: Icons.notifications_active_rounded),
                    ]),
                    _section(tr('sec_test'), [
                      ListTile(
                        leading: Icon(Icons.speed_rounded, color: Pal.cyan),
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
                      _note(tr('ping_tcp_note')),
                      ListTile(
                        leading: Icon(Icons.link_rounded, color: Pal.cyan),
                        title: Text(tr('opt_test_url')),
                        trailing: DropdownButton<String>(
                          value: kTestUrls.containsKey(s.testUrl) ? s.testUrl : kTestUrls.keys.first,
                          underline: const SizedBox(),
                          items: [for (final e in kTestUrls.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                          onChanged: (v) {
                            if (v != null) _set(() => s.testUrl = v);
                          },
                        ),
                      ),
                    ]),
                    _section(tr('sec_network'), [
                      _switch(tr('bypass_iran'), s.bypassIran, (v) => s.bypassIran = v, icon: Icons.shield_moon_rounded),
                      _switch(tr('opt_panel_tuning'), s.panelTuning, (v) {
                        s.panelTuning = v;
                        s.updatedMs = 0; // re-download the subscription in the matching format
                      }, sub: tr('opt_panel_tuning_sub'), icon: Icons.tune_rounded),
                      _switch(tr('opt_fragment'), s.fragment, (v) => s.fragment = v, icon: Icons.content_cut_rounded),
                      _switch(tr('opt_mux'), s.mux, (v) => s.mux = v, icon: Icons.merge_type_rounded),
                      if (!Platform.isWindows) _switch(tr('opt_ipv6'), s.ipv6, (v) => s.ipv6 = v, icon: Icons.public_rounded),
                      _switch(tr('opt_block_quic'), s.blockQuic, (v) => s.blockQuic = v,
                          sub: tr('opt_block_quic_sub'), icon: Icons.speed_rounded),
                      _switch(tr('opt_ads'), s.blockAds, (v) => s.blockAds = v, icon: Icons.block_rounded),
                      if (!Platform.isWindows)
                      ListTile(
                        leading: Icon(Icons.straighten_rounded, color: Pal.cyan),
                        title: const Text('MTU'),
                        subtitle: Text(tr('mtu_note'), style: TextStyle(fontSize: 12.5, color: Pal.t3)),
                        trailing: DropdownButton<int>(
                          value: const [1500, 1400, 1280].contains(s.mtu) ? s.mtu : 1500,
                          underline: const SizedBox(),
                          items: const [
                            DropdownMenuItem(value: 1500, child: Text('1500')),
                            DropdownMenuItem(value: 1400, child: Text('1400')),
                            DropdownMenuItem(value: 1280, child: Text('1280')),
                          ],
                          onChanged: (v) {
                            if (v != null) _set(() => s.mtu = v);
                          },
                        ),
                      ),
                      ListTile(
                        leading: Icon(Icons.dns_rounded, color: Pal.cyan),
                        title: Text(tr('opt_dns')),
                        trailing: DropdownButton<String>(
                          value: kDns.containsKey(s.dns) ? s.dns : 'google',
                          underline: const SizedBox(),
                          items: [for (final e in kDnsNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                          onChanged: (v) {
                            if (v != null) _set(() => s.dns = v);
                          },
                        ),
                      ),
                      _note(tr('apply_next')),
                    ]),
                    _section(tr('sec_security'), [
                      _switch(tr('opt_https_only'), s.httpsOnly, (v) => s.httpsOnly = v, icon: Icons.lock_rounded),
                      if (!Platform.isWindows)
                      ListTile(
                        leading: Icon(Icons.vpn_lock_rounded, color: Pal.cyan),
                        title: Text(tr('sys_vpn')),
                        trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                        onTap: () => Core.vpnSettings(),
                      ),
                      _note(tr('sec_note')),
                    ]),
                    if (Platform.isWindows)
                      _section(tr('sec_windows'), [
                        _switch(tr('opt_autostart'), s.winAutostart, (v) {
                          s.winAutostart = v;
                          WinCore.setAutostart(v);
                        }, icon: Icons.play_circle_outline_rounded),
                        ListTile(
                          leading: Icon(Icons.folder_open_rounded, color: Pal.cyan),
                          title: Text(tr('show_logs')),
                          onTap: () => WinCore.openLogs(),
                        ),
                        _note(tr('win_note')),
                      ]),
                    _section(tr('app_update'), [
                      ListTile(
                        leading: Icon(Icons.system_update_rounded, color: Pal.cyan),
                        title: Text(tr('check_update')),
                        subtitle: Directionality(
                          textDirection: TextDirection.ltr,
                          child: Text('${tr('version')} $kVersion  (build $kBuild)',
                              style: TextStyle(fontSize: 12.5, color: Pal.t3)),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdatePage())),
                      ),
                    ]),
                    _section(tr('sec_support'), [
                      ListTile(
                        leading: Icon(Icons.support_agent_rounded, color: Pal.cyan),
                        title: Text(tr('support')),
                        subtitle: const Text('@$kSupportUser'),
                        onTap: () => openTelegram(kSupportUser),
                      ),
                      ListTile(
                        leading: Icon(Icons.send_rounded, color: Pal.cyan),
                        title: Text(tr('channel')),
                        subtitle: const Text(kChannelText),
                        onTap: () => openTelegram(kChannelUser),
                      ),
                      ListTile(
                        leading: Icon(Icons.share_rounded, color: Pal.cyan),
                        title: Text(tr('share_app')),
                        onTap: () => Core.share('$kAppName\nhttps://t.me/$kChannelUser'),
                      ),
                      ListTile(
                        leading: Icon(Icons.restart_alt_rounded, color: Pal.cyan),
                        title: Text(tr('reset_defaults')),
                        onTap: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              content: Text(tr('reset_confirm')),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('ok'))),
                              ],
                            ),
                          );
                          if (ok == true) {
                            s.resetSettings();
                            await s.save();
                            if (mounted) setState(() {});
                          }
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.info_outline_rounded, color: Pal.cyan),
                        title: Text(tr('about')),
                        subtitle: Text(tr('about_text')),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Center(child: Text(kAppName, style: TextStyle(color: Pal.t4))),
                      ),
                    ]),
                  ]),
                ),
      ]);
      return widget.embedded ? content : Scaffold(body: Backdrop(child: SafeArea(child: content)));
    });
  }
}
