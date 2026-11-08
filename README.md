<div align="center">

<img src="docs/banner.png" alt="DastRas NG" width="100%"/>

**A fast, modern, Xray-powered VPN client for Android**
<br/>
**یک کلاینت سریع، مدرن و مبتنی بر هسته‌ی Xray برای اندروید**

<br/>

[![Release](https://img.shields.io/github/v/release/mojyrayzor-prog/dastras-ng?label=release&color=3563E9&style=for-the-badge)](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/mojyrayzor-prog/dastras-ng/total?color=0FA968&style=for-the-badge)](https://github.com/mojyrayzor-prog/dastras-ng/releases)
[![Telegram](https://img.shields.io/badge/Telegram-@dastras-26A5E4?logo=telegram&logoColor=white&style=for-the-badge)](https://t.me/dastras)
![Platform](https://img.shields.io/badge/Android-7.0%2B-3DDC84?logo=android&logoColor=white&style=for-the-badge)
![Core](https://img.shields.io/badge/Core-Xray-000000?style=for-the-badge)
![Flutter](https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white&style=for-the-badge)

**[English](#-english) · [فارسی](#-فارسی)**

</div>

---

## 🇬🇧 English

### ✨ Highlights

| | |
|---|---|
| 🚀 **Smart auto-connect** | Tests every server (latency + stability) before connecting and picks the best one for your network |
| 📶 **Network-aware** | Detects whether you are on mobile data (by operator) or Wi-Fi / modem / fiber and prefers the server family that works best there |
| 🔁 **Seamless server switch** | Tap another server while connected and it reconnects by itself |
| 📊 **Live speed** | Real-time download / upload, session usage, graph and a live notification with a *Disconnect* button |
| 🧩 **Per-app proxy** | Send only the apps you choose through the VPN, or everything except them |
| 🔗 **Subscriptions** | Links and JSON subscriptions (Marzban), auto-refresh, usage bar, copy / share the link |
| ⏰ **Account alerts** | Warns when data is almost gone or the account is about to expire, with one tap to message support on Telegram |
| 📣 **Announcements** | Publish a message to all customers by editing a single JSON file |
| 🔄 **In-app updates** | Reads new releases from GitHub, shows the changelog and installs the update |
| 🎨 **Modern design** | Light / dark / system themes, floating glass tab bar, Persian and English, Jalali dates |
| 🔒 **Privacy first** | No accounts, no analytics. Servers are stored encrypted, backups are disabled, no local proxy port is opened |
| ⚙️ **Tunable** | Block QUIC, MTU, DNS, TLS fragment, Mux, IPv6, ad blocking, bypass Iranian sites |

### 📥 Download

Get the newest version from the **[Releases page](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest)**.

| File | For |
|---|---|
| [`app-arm64-v8a-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-arm64-v8a-release.apk) | Almost all modern phones (recommended) |
| [`app-armeabi-v7a-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-armeabi-v7a-release.apk) | Older 32-bit phones |
| [`app-x86_64-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-x86_64-release.apk) | Emulators, some tablets |
| [`app-universal-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-universal-release.apk) | Works everywhere (bigger file) |

> **First install:** Android may show a warning for apps installed outside Google Play. Tap **Install anyway**.

### 🚀 Quick start

1. Install the APK and open the app (choose your language).
2. Copy your **subscription link** (or a `vless://`, `vmess://`, `trojan://`, `ss://` link). The app offers to add it automatically, or tap **Servers → ＋**.
3. Press the big power button. That's it.

### 🧠 Auto-select and network profile

Before connecting, the app measures every server and chooses the one with the lowest delay and the best stability.
If your servers are numbered (`DE 1`, `DE 2` …) the app can also use the network you are on:

| Your network | Preferred servers |
|---|---|
| Mobile data – Hamrah-e-Aval (MCI) | numbered **1** (Trojan) |
| Mobile data – Irancell / Rightel, Wi-Fi, modem, fiber | numbered **2** (VLESS) |

You can change this in *Settings → Automation → Network profile*. If the preferred servers fail, all other servers are tested too.

### 🔧 For panel admins (Marzban)

* The app reads `subscription-userinfo`, `profile-title` and `support-url` headers.
* It first asks for plain share links (fast). Turn on **“Server's own anti-filter settings”** to use the panel's JSON with its fragment / mux.
* Fake “info” servers (user name, days left) are shown but never auto-selected.

### 📣 Announcements to customers

Edit [`announcements.json`](announcements.json) in this repository and commit:

```json
[
  {
    "id": 2,
    "title": "Maintenance tonight",
    "body": "Servers will be updated at 23:00.",
    "url": "https://t.me/dastras/123",
    "date": "2026-11-10"
  }
]
```

`id` must always be bigger than the previous one. Customers receive it within ~10–15 minutes (as a notification while the VPN is connected, or in the inbox when the app is open).

### 🛠 Build from source

The whole build runs on GitHub Actions (`.github/workflows/build.yml`): it compiles the latest [libXray](https://github.com/XTLS/libXray) / Xray-core, builds the Flutter app and publishes a release with the APKs.

Optional release signing: add the repository secrets `KEYSTORE_B64` and `KEYSTORE_PASSWORD`. Without them a debug key is used.

### ❓ FAQ

<details>
<summary>The VPN icon stays after disconnecting</summary>

The VPN runs in its own process that is closed on disconnect, so the icon disappears. If it ever stays, force-stop the app and report it to support.
</details>

<details>
<summary>Speed is slower than expected</summary>

Keep *Mux* and *server anti-filter settings* off, keep *Block QUIC* on, and try MTU 1400. Choose a server from the other family in *Servers*.
</details>

<details>
<summary>Update fails with “App not installed”</summary>

Updates only install over the old version when both are signed with the same key. Uninstall the old version once, then install the new one.
</details>

### 🙏 Credits

[Xray-core](https://github.com/XTLS/Xray-core) · [libXray](https://github.com/XTLS/libXray) · [Flutter](https://flutter.dev) · geo data from the Iran-v2ray-rules / v2ray-rules-dat projects. Please see each project for its license.

### 📮 Support

Telegram channel: **[@dastras](https://t.me/dastras)** · Support: **[@xAdministrator](https://t.me/xAdministrator)**

---

<div dir="rtl" align="right">

## 🇮🇷 فارسی

### ✨ ویژگی‌ها

| | |
|---|---|
| 🚀 **اتصال خودکار هوشمند** | قبل از اتصال همه‌ی سرورها از نظر تأخیر و پایداری تست می‌شوند و بهترین سرور برای شبکه‌ی شما انتخاب می‌شود |
| 📶 **آگاه از شبکه** | تشخیص می‌دهد روی اینترنت همراه (به‌تفکیک اپراتور) هستید یا وای‌فای، مودم و فیبر و خانواده‌ی سرور مناسب را اولویت می‌دهد |
| 🔁 **تعویض بدون دردسر سرور** | وسط اتصال روی سرور دیگری بزنید، خودش دوباره وصل می‌شود |
| 📊 **سرعت لحظه‌ای** | سرعت دانلود و آپلود، مصرف همین اتصال، نمودار و نوتیفیکیشن زنده با دکمه‌ی «قطع اتصال» |
| 🧩 **پروکسی برنامه‌ها** | فقط برنامه‌های انتخابی یا همه به‌جز آن‌ها از VPN استفاده کنند |
| 🔗 **اشتراک‌ها** | لینک و ساب JSON (مرزبان)، به‌روزرسانی خودکار، نوار حجم، کپی و اشتراک‌گذاری لینک |
| ⏰ **هشدار اکانت** | وقتی حجم رو به اتمام است یا اکانت دارد تمام می‌شود هشدار می‌دهد و با یک لمس در تلگرام به پشتیبانی پیام می‌دهد |
| 📣 **اعلان به مشتریان** | با ویرایش یک فایل JSON برای همه‌ی مشتری‌ها پیام بفرستید |
| 🔄 **به‌روزرسانی داخل برنامه** | نسخه‌ی جدید را از گیت‌هاب می‌خواند، تغییرات را نشان می‌دهد و نصب می‌کند |
| 🎨 **طراحی مدرن** | تم سفید، تیره و سیستم، نوار تب شیشه‌ای شناور، فارسی و انگلیسی، تاریخ شمسی |
| 🔒 **حریم خصوصی** | بدون ثبت‌نام و بدون ردیابی. سرورها رمزنگاری‌شده ذخیره می‌شوند و هیچ پورت محلی باز نمی‌شود |
| ⚙️ **قابل تنظیم** | مسدودسازی QUIC، MTU، DNS، فرگمنت TLS، Mux، IPv6، مسدودکردن تبلیغات، عبور مستقیم سایت‌های ایرانی |

### 📥 دانلود

آخرین نسخه را از **[صفحه‌ی Releases](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest)** بگیرید.

| فایل | مناسب برای |
|---|---|
| [`app-arm64-v8a-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-arm64-v8a-release.apk) | تقریباً همه‌ی گوشی‌های امروزی (پیشنهادی) |
| [`app-armeabi-v7a-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-armeabi-v7a-release.apk) | گوشی‌های قدیمی ۳۲ بیتی |
| [`app-x86_64-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-x86_64-release.apk) | شبیه‌ساز و بعضی تبلت‌ها |
| [`app-universal-release.apk`](https://github.com/mojyrayzor-prog/dastras-ng/releases/latest/download/app-universal-release.apk) | روی همه‌ی گوشی‌ها کار می‌کند (حجم بیشتر) |

> **نصب اول:** اندروید برای برنامه‌هایی که از گوگل‌پلی نصب نشده‌اند هشدار می‌دهد. گزینه‌ی **Install anyway** را بزنید.

### 🚀 شروع سریع

1. فایل APK را نصب و برنامه را باز کنید (زبان را انتخاب کنید).
2. **لینک ساب** (یا لینک `vless://`، `vmess://`، `trojan://`، `ss://`) را کپی کنید. برنامه خودش پیشنهاد افزودن می‌دهد، یا از تب **سرورها** دکمه‌ی ＋ را بزنید.
3. دکمه‌ی بزرگ وسط صفحه را بزنید. تمام!

### 🧠 انتخاب خودکار و پروفایل شبکه

برنامه قبل از اتصال همه‌ی سرورها را می‌سنجد و سروری را که کمترین تأخیر و بیشترین پایداری را دارد انتخاب می‌کند.
اگر سرورهای شما شماره‌دار باشند (`DE 1`، `DE 2` …) برنامه شبکه‌ای را که روی آن هستید هم در نظر می‌گیرد:

| شبکه‌ی شما | سرورهای اولویت‌دار |
|---|---|
| اینترنت همراه، همراه اول | سرورهای شماره‌ی **۱** (تروجان) |
| اینترنت همراه ایرانسل و رایتل، وای‌فای، مودم، فیبر | سرورهای شماره‌ی **۲** (VLESS) |

این گزینه از مسیر *تنظیمات ← خودکارسازی ← پروفایل شبکه* قابل تغییر است. اگر سرورهای اولویت‌دار کار نکنند، بقیه‌ی سرورها هم تست می‌شوند.

### 🔧 برای مدیران پنل (مرزبان)

* هدرهای `subscription-userinfo`، `profile-title` و `support-url` خوانده می‌شوند.
* برنامه اول لینک‌های ساده را می‌گیرد (سریع‌تر). گزینه‌ی **«تنظیمات ضدفیلتر خود سرور»** را روشن کنید تا از JSON پنل با فرگمنت و Mux خودش استفاده شود.
* سرورهای «اطلاعاتی» (نام کاربر، روزهای باقی‌مانده) نمایش داده می‌شوند ولی هرگز خودکار انتخاب نمی‌شوند.

### 📣 اعلان به مشتریان

فایل [`announcements.json`](announcements.json) را در همین مخزن ویرایش و Commit کنید:

```json
[
  {
    "id": 2,
    "title": "تعمیرات امشب",
    "body": "ساعت ۲۳ سرورها به‌روزرسانی می‌شوند.",
    "url": "https://t.me/dastras/123",
    "date": "2026-11-10"
  }
]
```

مقدار `id` باید همیشه از قبلی بزرگ‌تر باشد. مشتری‌ها حدود ۱۰ تا ۱۵ دقیقه بعد پیام را می‌گیرند (به‌صورت اعلان وقتی VPN وصل است، یا در صندوق پیام‌ها وقتی برنامه باز است).

### 🛠 ساخت از روی سورس

کل ساخت روی GitHub Actions انجام می‌شود (`.github/workflows/build.yml`): آخرین [libXray](https://github.com/XTLS/libXray) و Xray-core را کامپایل می‌کند، برنامه‌ی Flutter را می‌سازد و یک Release با فایل‌های APK منتشر می‌کند.

امضای اختصاصی (اختیاری): دو Secret به نام‌های `KEYSTORE_B64` و `KEYSTORE_PASSWORD` اضافه کنید. بدون آن‌ها از کلید موقت استفاده می‌شود.

### ❓ سؤالات متداول

<details>
<summary>بعد از قطع کردن، علامت VPN بالای گوشی می‌ماند</summary>

سرویس VPN در یک پردازه‌ی جدا اجرا می‌شود که هنگام قطع بسته می‌شود و علامت کلید برداشته می‌شود. اگر باز هم ماند، برنامه را از تنظیمات گوشی «توقف اجباری» کنید و به پشتیبانی خبر بدهید.
</details>

<details>
<summary>سرعت کمتر از انتظار است</summary>

گزینه‌های *Mux* و *تنظیمات ضدفیلتر سرور* را خاموش و *مسدود کردن QUIC* را روشن نگه دارید و MTU را روی ۱۴۰۰ امتحان کنید. از تب سرورها یک سرور از خانواده‌ی دیگر را انتخاب کنید.
</details>

<details>
<summary>آپدیت با خطای «App not installed» روبه‌رو می‌شود</summary>

آپدیت فقط وقتی روی نسخه‌ی قبلی نصب می‌شود که هر دو نسخه با یک کلید امضا شده باشند. یک‌بار نسخه‌ی قدیمی را پاک و نسخه‌ی جدید را نصب کنید.
</details>

### 🙏 قدردانی

[Xray-core](https://github.com/XTLS/Xray-core) · [libXray](https://github.com/XTLS/libXray) · [Flutter](https://flutter.dev) · داده‌های geo از پروژه‌های Iran-v2ray-rules و v2ray-rules-dat. لایسنس هر پروژه را در مخزن خودش ببینید.

### 📮 پشتیبانی

کانال تلگرام: **[@dastras](https://t.me/dastras)** · پشتیبانی: **[@xAdministrator](https://t.me/xAdministrator)**

</div>
