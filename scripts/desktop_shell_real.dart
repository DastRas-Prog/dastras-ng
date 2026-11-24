import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'lang.dart';

/// System-tray icon with a menu, and "close to tray" for Windows and macOS.
class DesktopShell with TrayListener, WindowListener {
  static final DesktopShell _i = DesktopShell._();
  DesktopShell._();

  static Future<void> Function()? _onToggle;
  static Future<void> Function()? _onExit;
  static bool _connected = false;
  static bool _ready = false;

  static Future<void> init({required bool startHidden}) async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      await windowManager.setMinimumSize(const Size(380, 640));
      windowManager.addListener(_i);
      trayManager.addListener(_i);
      await trayManager.setIcon(Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png');
      await trayManager.setToolTip('DastRas NG');
      await _menu();
      _ready = true;
      if (startHidden) await windowManager.hide();
    } catch (_) {}
  }

  static void handlers({Future<void> Function()? onToggle, Future<void> Function()? onExit}) {
    _onToggle = onToggle;
    _onExit = onExit;
  }

  static Future<void> setConnected(bool v) async {
    _connected = v;
    if (!_ready) return;
    try {
      await _menu();
    } catch (_) {}
  }

  static Future<void> setTip(String text) async {
    if (!_ready) return;
    try {
      await trayManager.setToolTip(text);
    } catch (_) {}
  }

  static Future<void> _menu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: tr('tray_show')),
      MenuItem(key: 'toggle', label: _connected ? tr('tray_disconnect') : tr('tray_connect')),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: tr('tray_exit')),
    ]));
  }

  static Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> quit() async {
    try {
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() async {
    await windowManager.hide(); // the app keeps running in the tray
  }

  @override
  void onTrayIconMouseDown() {
    _show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _show();
        break;
      case 'toggle':
        await _onToggle?.call();
        break;
      case 'exit':
        await _onExit?.call();
        await quit();
        break;
    }
  }
}
