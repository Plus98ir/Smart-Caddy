<h1 align="center">Smart-Caddy</h1>

<p align="center"><a href="https://hits.sh/github.com/Plus98ir/Smart-Caddy/"><img src="https://hits.sh/github.com/Plus98ir/Smart-Caddy.svg?style=for-the-badge&label=views&color=2563eb" alt="Views"></a> <a href="https://corenetbase.com/#support"><img src="https://img.shields.io/badge/support-buy%20me%20a%20coffee-e11d2a?style=for-the-badge&logo=buymeacoffee&logoColor=white" alt="Support"></a></p>

<details>
<summary><b>☕ Support · حمایت</b> — USDT (TRC20) / TRX</summary>
<br>
<p align="center"><img src="https://raw.githubusercontent.com/Plus98ir/.github/main/tron-qr.png" width="200" alt="TRON address QR"></p>

```
TA53aFyGNfSAcrCaJi9QmA9x5W47nPJcf7
```

> [!WARNING]
> **TRON network only.** Sending from ERC20 / BEP20 will lose the funds.<br>
> **فقط شبکه‌ی TRON.** ارسال از ERC20 یا BEP20 پول را از بین می‌برد.

</details>

<details>
<summary><b>🇮🇷 فارسی</b></summary>

مدیریت هوشمند reverse proxy روی [Caddy](https://caddyserver.com)، در یک اسکریپت.

<div dir="rtl" align="right">

دامنه می‌دهی → کانفیگ را می‌نویسد، گواهی می‌گیرد، اعتبارسنجی می‌کند و reload می‌زند.
اگر چیزی ایراد داشته باشد **خودش برمی‌گرداند**، پس Caddy هیچ‌وقت نمی‌افتد.

</div>

```
$ sudo smart-caddy add panel.example.com 54321

== Pre-flight checks ==
[ ok ] DNS -> 203.0.113.10
[ ok ] backend 127.0.0.1:54321 is reachable
[info] no certificate yet - Caddy will obtain one right after reload

== Applying ==
[ ok ] Caddy reloaded with no downtime.
[info] waiting for certificate issuance....
[ ok ] certificate issued, expires: Dec 20 14:02:11 2026 GMT

== Done ==
[ ok ] https://panel.example.com  ->  127.0.0.1:54321
```

---

<div dir="rtl" align="right">

## نصب

</div>

```bash
curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh && sudo bash smart_caddy.sh
```

<div dir="rtl" align="right">

این آدرس همیشه به آخرین نسخه می‌رسد — شماره‌ای نیست که لازم باشد عوضش کنی.

یک فایل، یک دستور. اگر Caddy نصب نباشد خودش نصبش می‌کند (apt، dnf، yum، pacman، apk)،
بعد به ماشین نگاه می‌کند و فقط چیزی را می‌پرسد که خودش نمی‌تواند بفهمد:

</div>

```
== Looking around ==
[ ok ] package manager: apt
[ ok ] Caddy is installed - v2.11.4
[ ok ] several addresses: 203.0.113.10 203.0.113.11
[warn] :443 is held by 'xray-linux-amd6'

       Caddy cannot share a port with another process. Your options:
         * if that is Xray, keep it and put sites behind its fallback:
               smart-caddy add <domain> <port> --behind-xray
         * if it is an old nginx/apache you no longer want, stop it first
         * or give Caddy its own IP on a multi-address host

== A few questions ==
  Address for Caddy (one of: 203.0.113.10 203.0.113.11) [203.0.113.10]:
  Email for Let's Encrypt (expiry notices) [admin@example.com]:
  Set up the web panel, so you can manage sites in a browser? [Y/n]
  Add your first site now? [y/N]
```

<div dir="rtl" align="right">

روی سرور تک‌IP اصلاً سؤال آدرس نمی‌پرسد. سورس پنل وب داخل خود اسکریپت جاسازی شده،
پس چیز دیگری برای دانلود نیست.

> **چرا اول دانلود و بعد اجرا، نه مستقیم دادن به bash؟**
>
> `curl ... | bash` ترمینالی برای سؤال پرسیدن باقی نمی‌گذارد و هر prompt بی‌صدا
> مقدار پیش‌فرض را برمی‌دارد. اسکریپت این را تشخیص می‌دهد و به‌جای حدس زدن امتناع
> می‌کند.
>
> `sudo bash -c "$(curl ...)"` کل اسکریپت را به‌صورت یک آرگومان خط فرمان می‌دهد و
> لینوکس هر آرگومان را به ۱۲۸ کیلوبایت محدود می‌کند. اسکریپت از این بزرگ‌تر است، پس
> خطای `Argument list too long` می‌گیری.
>
> `sudo bash <(curl ...)` هم کار نمی‌کند: sudo فایل `/dev/fd/63` را که process
> substitution می‌سازد می‌بندد و خطای `/dev/fd/63: No such file or directory` می‌دهد.
>
> ذخیرهٔ فایل و اجرای آن هیچ‌کدام از این مشکلات را ندارد، ترمینال را برای سؤال‌ها وصل
> نگه می‌دارد، و اگر بخواهی می‌توانی اول اسکریپت را بخوانی:
>
> ```bash
> curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh
> less smart_caddy.sh      # اول بخوانش
> sudo bash smart_caddy.sh
> ```

از قبل نصب است؟ در جا آپدیت کن:

```bash
sudo smart-caddy update
```

## چه کارهایی می‌کند

| | |
|---|---|
| **هیچ‌وقت سرور را خراب نمی‌کند** | قبل از هر reload یک `caddy validate`؛ هر خطا = برگشت خودکار |
| **`bind` خودکار** | روی سرورهای چند‌IP همیشه می‌نویسدش، پس تصادم پورت پیش نمی‌آید |
| **نوشتن امن فایل** | Caddyfile را در جا ویرایش می‌کند، بدون خراب کردن مجوز و مالکیت |
| **گواهی خودکار** | Caddy همهٔ گواهی‌ها را خودش می‌گیرد و تمدید می‌کند؛ پنل تعداد روزهای باقی‌مانده را نشان می‌دهد و دکمهٔ **تمدید** دارد که اگر چیزی خراب شود گواهی قبلی را برمی‌گرداند |
| **Caddy موجود را می‌پذیرد** | سایت‌هایی را که مستقیم در Caddyfile نوشته‌ای پیدا می‌کند و بدون تغییر وارد می‌کند تا در پنل دیده شوند |
| **مسیرها (routes)** | مثلاً `/dns-query/*` یا `/api/*` را به مقصدی غیر از بقیهٔ سایت بفرست |
| **ریالیتی روی `:443`** | اینباندهای ریالیتی x-ui پورت `:443` را با سایت‌ها شریک می‌شوند و هر دقیقه همگام می‌مانند - از طریق DNSGuard، یا **مسیریاب SNI خود Caddy** (caddy-l4) روی سرورهای بدون آن |
| **IP واقعی بازدیدکننده پشت Cloudflare** | فقط به سرورهای Cloudflare اعتماد می‌شود و `CF-Connecting-IP` فقط از آن‌ها خوانده می‌شود؛ پس برنامه‌ها و Xray خود کاربر را ثبت می‌کنند نه Cloudflare را |
| **به‌روزرسانی از پنل** | تنظیمات ← به‌روزرسانی، آخرین نسخه را از نظر محتوا چک و نصب می‌کند؛ سایت‌ها روشن می‌مانند |
| **کانفیگ‌های Xray پشت Cloudflare** | یک مسیر مخفی را به اینباند XHTTP / gRPC (`h2c://`) یا WebSocket / HTTPUpgrade بفرست تا ابر نارنجی IP سرور را مخفی کند؛ پنل یک راهنمای قدم‌به‌قدم دارد |
| **هویت سرور** | برای هر سرور نام، آیکون (پرچم هم می‌شود) و رنگ بگذار: در تب مرورگر، favicon، بالای پنل و صفحهٔ ورود دیده می‌شود تا چند پنل هیچ‌وقت قاطی نشوند |
| **گزارش تغییرات** | همهٔ تغییرات، چه از پنل چه از ترمینال: چه کسی، کی، خروجی، و diff دقیق خطوطی از کانفیگ که عوض شد |
| **انواع بک‌اند** | پورت محلی، بک‌اند TLS، پوشهٔ فایل، سایت دیگر، یا ریدایرکت |
| **آگاه از path، ولی شکننده نه** | مسیر پایهٔ اپ را ثبت می‌کند بدون اینکه بقیه را ۴۰۴ کند، پس WebSocket پنل‌ها سالم می‌ماند |
| **پشت یک پروکسی دیگر** | وقتی یک SNI proxy مثل DNSGuard پورت‌های `:80`/`:443` را دارد و دامنه‌ها را روی loopback به Caddy می‌دهد، سایت‌ها پشت آن ساخته می‌شوند و دامنه خودکار در آن ثبت می‌شود |
| **همزیستی با Xray** | `--behind-xray` لیسنر loopback + PROXY protocol + h2c را می‌چیند و وجود fallback را چک می‌کند |
| **پنل وب** | طراحی تیره و شیشه‌ای با تب‌ها، فارسی / انگلیسی، صفحهٔ ورود واقعی، رمز PBKDF2، نشست امضاشده، افزودن / **ویرایش** / حذف سایت، ویرایشگر متن خام کانفیگ |
| **حذف امن** | موقع حذف می‌پرسد گواهی بماند یا برود (پیش‌فرض: بماند) |
| **`doctor`** | پورت‌ها، bind، DNS، مجوزها، گواهی‌هایی که تمدید نمی‌شوند، تله‌های WebSocket، fallbackهای Xray، خطاهای اخیر |
| **`repair`** | مجوزها، بلاک‌های احراز هویت کهنه و پین نسخهٔ HTTP جاافتاده را درست می‌کند |

## پنل وب

</div>

```bash
sudo smart-caddy panel                    # دامنه را می‌پرسد
sudo smart-caddy panel caddy.example.com  # یا از اول بگو
```

<div dir="rtl" align="right">

یک سرویس فقط روی localhost، پشت Caddy با TLS. سایت‌ها را فهرست می‌کند، اضافه می‌کند،
**ویرایش** می‌کند، حذف می‌کند و تشخیص می‌زند — همه با صدا زدن همان CLI زیرین، یعنی
فقط یک مسیر کد وجود دارد که کانفیگ می‌نویسد.

یک رابط تیره و شیشه‌ای (Glassmorphism)، **فارسی و انگلیسی** (در فارسی راست‌به‌چپ)،
مرتب‌شده در تب‌ها که هر کدام عنوان و توضیح خودش را دارد:

- **داشبورد** — وضعیت Caddy، تعداد گواهی‌ها، گواهی‌های نزدیک به انقضا و میان‌برها.
- **سایت‌ها** — هر سایت با مقصد، مسیرها و **تعداد روزهای باقی‌ماندهٔ SSL** که با
  نزدیک شدن انقضا رنگش عوض می‌شود، به‌همراه دکمهٔ **تمدید**.
- **افزودن / ویرایش سایت** — اول «چه چیزی را آنلاین می‌کنید؟» (سایت، پنل x-ui، کانفیگ
  Xray از طریق CDN) با راهنمای قدم‌به‌قدم و دکمهٔ **پر کردن خودکار از x-ui** (پورت پنل،
  مسیر پایه و ساب از خود x-ui)؛ بعد یک فرم با توضیح زیر هر فیلد: **نام** سایت، مقصد
  اصلی، **مسیرها** (هر کدام با نوع تیک‌دار *وب / ساب*، *WebSocket / HTTPUpgrade* یا
  *XHTTP / gRPC*؛ `/` اول و `*` آخر خودکار اضافه می‌شوند)،
  گواهی SSL (Caddy، certbot موجود، یا خودامضا)، پیشوند مسیر، هدر Host، پیش‌تنظیم پنل
  مدیریتی، HTTP ساده، پشت Xray.
- **کانفیگ** — متن خام Caddyfile هر سایت را ویرایش کن. اول بررسی می‌شود و اگر Caddy
  قبول نکند برمی‌گردد، پس یک اشتباه تایپی سرور را از کار نمی‌اندازد.
- **وارد کردن** — سایت‌هایی که دستی در Caddyfile نوشته شده‌اند، با وارد کردن
  تک‌کلیکی. دامنه‌ای که دو بار تعریف شده دکمهٔ «همین را نگه دار» می‌گیرد.
- **CDN کلودفلر** — کدام ترنسپورت‌های Xray پشت Cloudflare کار می‌کنند و قدم‌های دقیق
  در x-ui، همین پنل و Cloudflare.
- **عیب‌یابی** و **گزارش تغییرات** — بررسی کامل، خروجی هر کار و هر تغییر با diff
  رنگی فایل‌های کانفیگ.
- **ریالیتی** — همهٔ اینباندهای ریالیتی x-ui، اینکه روی `:443` هستند یا نه، لینک‌های
  اشتراک، دکمهٔ **ببر روی 443**، و روی سرور بدون DNSGuard کلید مسیریاب SNI خود Caddy.
  بخش «ریالیتی روی ۴۴۳» را ببین.
- **تنظیمات** — **به‌روزرسانی** (بررسی آخرین نسخه و نصبش از همین صفحه) و هویت سرور: نام، آیکون و رنگ که در تب مرورگر، favicon، بالای پنل و
  صفحهٔ ورود دیده می‌شوند. در `/etc/smart-caddy-brand.json` ذخیره می‌شود و آپدیت به آن
  دست نمی‌زند.

صفحهٔ ورود واقعی دارد، نه آن پاپ‌آپ بومی مرورگر: رمزها با PBKDF2-HMAC-SHA256
(۲۴۰ هزار دور) در `/etc/smart-caddy-panel.json` با مجوز `0600`، نشست‌ها کوکی امضاشده
با HMAC (`HttpOnly`، `SameSite=Strict`، و `Secure` پشت HTTPS) که بعد از restart هم
باقی می‌مانند، POST از دامنهٔ دیگر رد می‌شود، و بعد از پنج تلاش ناموفق تأخیر نمایی
اعمال می‌شود.

رمز را هر وقت خواستی از ترمینال عوض کن:

</div>

```bash
sudo smart-caddy passwd                          # دوبار می‌پرسد
sudo smart-caddy passwd --password 'NewPass123'
sudo smart-caddy passwd newuser                  # یوزرنیم را هم عوض کن
```

<div dir="rtl" align="right">

تغییر رمز کلید امضای نشست را هم می‌چرخاند، پس هر کسی که لاگین بوده بیرون می‌افتد.

نکته‌ها:

- سرویس فقط روی `127.0.0.1` گوش می‌دهد. احراز هویت دارد ولی HTTP ساده حرف می‌زند —
  Caddy را جلویش نگه دار، پورت را مستقیم باز نکن.
- با root اجرا می‌شود، چون `/etc/caddy` را ویرایش و سرویس را reload می‌کند.
- هر فیلد قبل از رسیدن به subprocess با allowlist سخت‌گیرانه اعتبارسنجی می‌شود، و
  دستورها به‌صورت لیست argv ساخته می‌شوند، نه رشتهٔ shell.

## دستورها

</div>

```
setup                                    یک دستور، از صفر تا صد
install [--ip <IP>] [--email <mail>]     فقط سیم‌کشی سیستم
add <domain> <backend> [opts]            افزودن سایت
del <domain> [--keep-cert|--purge-cert]  حذف سایت
del-cert <domain>                        حذف فقط گواهی
list                                     فهرست سایت‌ها و گواهی‌ها
import [domain...] [--all|--list]        وارد کردن سایت‌هایی که در Caddyfile هستند
import <domain> --replace                ... به‌جای نسخهٔ مدیریت‌شدهٔ همان دامنه
put <domain> <file>                      جایگزینی کانفیگ سایت با متن خودت
cert <domain> caddy                      سپردن گرفتن و تمدید گواهی به Caddy
renew <domain>                           گرفتن گواهی تازه همین حالا (در صورت خطا برمی‌گردد)
panel <domain> [--user u] [--port n]     نصب پنل وب
panel status | panel remove [<domain>]   بررسی یا حذف پنل وب
passwd [user] [--password <p>]           تغییر رمز پنل
doctor                                   تشخیص کامل
fixbind                                  افزودن bind به بلاک‌های بدون bind
repair                                   رفع مجوزها و مشکلات شناخته‌شدهٔ آپگرید
update [--force]                         نصب آخرین نسخه (در پنل هم هست)
reality [status|sync|on443 <id>]         ریالیتی‌های x-ui روی 443
sni [status|enable|disable]              مسیریاب SNI خود Caddy (caddy-l4)
uninstall                                برداشتن ادغام (گواهی‌ها می‌مانند)
```

<div dir="rtl" align="right">

`add` و `panel` را بدون آرگومان اجرا کن، خودشان قدم‌به‌قدم می‌پرسند و ورودی غلط را
قبول نمی‌کنند.

### بک‌اندها

| می‌نویسی | یعنی |
|---|---|
| `54321` | پورتی روی همین ماشین |
| `127.0.0.1:54321` | همان، با جزئیات |
| `https://127.0.0.1:27389` | اپ محلی که خودش TLS سرو می‌کند (همراه با `--insecure`) |
| `10.0.0.5:9000` | سرویسی روی ماشین دیگر |
| `/var/www/mysite` | فایل‌ها را از این پوشه سرو کن |
| `example.com` | پروکسی به سایت شخص دیگر |
| `redirect:https://x.com` | بازدیدکننده را بفرست آن‌جا |

اگر `host:port` ساده بدهی ولی بک‌اند در واقع HTTPS حرف بزند، خودش تشخیص می‌دهد و
پیشنهاد عوض کردن می‌دهد — این ناهماهنگی رایج‌ترین علت ۵۰۲ است.

### گزینه‌های `add`

| گزینه | کار |
|---|---|
| `--route <path>=<backend>` | یک مسیر را به مقصد دیگری بفرست، مثلاً `--route '/dns-query/*=8000'`. قابل تکرار. |
| `--replace` | سایت موجود را در جا بازنویسی کن (گواهی و پورت loopback پشت Xray حفظ می‌شود) |
| `--path <prefix>` | مسیر پایهٔ اپ را ثبت کن، در `list` نشان داده می‌شود. قابل تکرار. |
| `--strict-path` | علاوه بر آن، هر چیزی بیرون از این مسیرها را رد کن |
| `--behind-xray` | Xray صاحب `:443` است و به ما fallback می‌کند |
| `--listen-port <n>` | پورت loopback را خودت انتخاب کن (پیش‌فرض: اولین آزاد در ۸۰۸۱–۸۱۹۹) |
| `--panel` | پیش‌تنظیم پنل‌های مدیریتی — یعنی `--insecure --no-buffer` |
| `--insecure` | گواهی TLS بک‌اند را بررسی نکن |
| `--no-buffer` | پاسخ‌ها را مستقیم پخش کن — آمار زنده، SSE، دنبال کردن لاگ |
| `--host-header <v>` | هدر `Host` ارسالی به بک‌اند را اجبار کن (روترها `127.0.0.1` می‌خواهند) |
| `--auto-cert` | Caddy خودش گواهی را بگیرد و تمدید کند (پیشنهادی) |
| `--certbot` | از گواهی موجود certbot استفاده کن |
| `--self-signed` | `tls internal` — CA داخلی Caddy، برای تست |
| `--no-tls` | فقط HTTP |
| `--no-dns-check` | بررسی رکورد A را رد کن |
| `-y, --yes` | بدون سؤال |

## پنل‌های مدیریتی (x-ui، 3x-ui، Marzban، Hiddify)

این‌ها سه کار دردسرساز را همزمان می‌کنند: روی localhost با **گواهی self-signed
سرویس HTTPS** می‌دهند، زیر یک **مسیر تصادفی** زندگی می‌کنند، و داشبوردشان
**شمارنده‌های ترافیک زنده** را استریم می‌کند. هر کدام را جا بیندازی، یا صفحهٔ سفید
می‌گیری، یا ۵۰۲، یا پنلی که باز می‌شود ولی هیچ‌وقت آپدیت نمی‌شود.

</div>

```bash
sudo smart-caddy add panel.example.com https://127.0.0.1:27389 \
    --panel --path /5wSobQvUFuNy4zBUcc
```

```caddyfile
panel.example.com {
	bind 203.0.113.10
	encode zstd gzip

	# app base path: /5wSobQvUFuNy4zBUcc
	reverse_proxy https://127.0.0.1:27389 {
		transport http {
			tls_insecure_skip_verify
			versions 1.1
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Port {server_port}

		flush_interval -1
	}
}
```

<div dir="rtl" align="right">

سه جزئیات مهم‌اند، و هر کدام به یک شکل **نامرئی** شکست می‌خورند:

- **`flush_interval -1`** — معادل `proxy_buffering off` در nginx. بدون آن،
  شمارنده‌های زندهٔ داشبورد در بافر می‌مانند و انگار یخ زده‌اند.
- **`versions 1.1`** — بک‌اند TLS می‌تواند از طریق ALPN روی HTTP/2 توافق کند، و
  HTTP/2 اصلاً مکانیزم Upgrade ندارد، پس هندشیک WebSocket بی‌صدا شکست می‌خورد.
- **روی پنل هرگز هدر `Host` را اجبار نکن.** پنل‌ها `Origin` وب‌سوکت را با `Host` که
  دریافت می‌کنند می‌سنجند. اگر `Host: 127.0.0.1` بفرستی در حالی که مرورگر
  `Origin: https://panel.example.com` می‌فرستد، آن بررسی رد می‌شود، وب‌سوکت بسته
  می‌شود و ستون‌های سرعت برای همیشه خالی می‌مانند. `add` اگر بخواهی این کار را بکنی
  هشدار می‌دهد.

### چرا `--path` به‌صورت پیش‌فرض محدود نمی‌کند

`--path` فقط ثبت می‌کند که اپ کجاست؛ چیزی را مسدود نمی‌کند. پنل‌های مدیریتی معمولاً
مسیر پایه‌شان یک جاست ولی وب‌سوکت آمار زنده را از **ریشهٔ سایت** باز می‌کنند. پس
اگر روی پیشوند مچ کنی و بقیه را ۴۰۴ کنی، پنلی می‌سازی که کاملاً سالم به‌نظر می‌رسد
در حالی که ستون‌های ترافیک زنده برای همیشه خالی‌اند — باگی که پیدا کردنش واقعاً
سخت است، چون هر صفحه‌ای کلیک کنی کار می‌کند.

خود اپ ریشه‌اش را ۴۰۴ می‌کند، پس آن محدودیت اضافه معمولاً چیزی به تو نمی‌دهد. اگر
واقعاً می‌خواهی، `--strict-path` رفتار سخت‌گیرانه را برمی‌گرداند، همراه با هشدار.

## از قبل Caddy داری؟

سایت‌هایی که دستی نوشته‌ای داخل خود Caddyfile هستند و هیچ ابزاری آن‌ها را نمی‌بیند.
`setup` و `install` پیدایشان می‌کنند و پیشنهاد وارد کردن می‌دهند؛ هر وقت هم خواستی:

</div>

```bash
sudo smart-caddy import --list     # چه چیزی آنجاست
sudo smart-caddy import            # انتقال به sites.d
```

<div dir="rtl" align="right">

هر بلاک **بایت‌به‌بایت** به `/etc/caddy/sites.d/<domain>.caddy` منتقل می‌شود، پس Caddy
دقیقاً همان چیزی را سرو می‌کند که قبلاً می‌کرد. اول از Caddyfile نسخهٔ پشتیبان گرفته
می‌شود و انتقال مثل هر تغییر دیگری بررسی و در صورت خطا برگردانده می‌شود. بلاک‌های بدون
نام دامنه (`:80`، IP، `localhost`) و snippetها سر جایشان می‌مانند.

اگر سایت واردشده فقط از دستورهایی استفاده کند که فرم پنل می‌شناسد (ریورس پروکسی،
مسیرها، فایل، ریدایرکت)، در فرم پنل باز می‌شود؛ بقیه با دکمهٔ **کانفیگ** به‌صورت متن خام
ویرایش می‌شوند.

## مسیرها (routes)

یک دامنه، چند مقصد. مثلاً یک سرور DNS-over-HTTPS با صفحهٔ مدیریت خودش و یک صفحهٔ عمومی:

</div>

```bash
sudo smart-caddy add dns.example.com 8088 \
    --route '/dns-query/*=8000' --route '/panel*=8000'
```

<div dir="rtl" align="right">

هر مسیر یک بلاک `handle` می‌شود و بقیهٔ درخواست‌ها به مقصد اصلی می‌روند.

## کانفیگ‌های Xray پشت Cloudflare

Caddy را بین Cloudflare و یک اینباند Xray بگذار: پینگ دامنه IP کلودفلر را برمی‌گرداند،
ولی ترافیک همچنان از همین سرور خارج می‌شود. روی یک دامنه چند کانفیگ جا می‌شود، هر کدام
روی مسیر مخفی خودش.

| ترنسپورت | پشت Cloudflare | نوع مسیر |
|---|---|---|
| XHTTP | بله (`packet-up` همه‌جا؛ حالت‌های stream به gRPC روشن در Cloudflare نیاز دارند) | `h2c://127.0.0.1:PORT` |
| gRPC | بله (Network ← gRPC را روشن کن) | `h2c://127.0.0.1:PORT` |
| WebSocket، HTTPUpgrade | بله | `127.0.0.1:PORT` |
| Reality، TCP، Hysteria2، Shadowsocks | خیر — Cloudflare فقط HTTP را رد می‌کند | — |

۱. در x-ui اینباند روی `127.0.0.1` گوش بدهد، security **none** باشد (TLS روی Caddy تمام
   می‌شود — اینباندی که TLS خودش را دارد `pinnedPeerCertSha256` را داخل لینک می‌گذارد و
   پشت Cloudflare این pin هیچ‌وقت جور نمی‌شود)، یک path تصادفی بلند و دامنهٔ CDN به‌عنوان Host.

۲. سایت را با ابر خاکستری، یک صفحهٔ پوششی به‌عنوان مقصد اصلی و برای هر کانفیگ یک مسیر اضافه کن:

</div>

```bash
sudo smart-caddy add cdn.example.com redirect:https://www.google.com \
    --route '/k8Jq2xVt*=h2c://127.0.0.1:3103' --route '/ws9Lp*=3305'
```

<div dir="rtl" align="right">

۳. وقتی گواهی صادر شد ابر را نارنجی کن؛ SSL/TLS روی **Full (strict)**؛ *Always Use HTTPS*
   خاموش بماند تا Caddy بتواند از پورت 80 تمدید کند.

۴. کلاینت: آدرس = دامنه یا یک IP تمیز کلودفلر، پورت 443، TLS، SNI و Host = دامنه؛ ALPN
   برای XHTTP/gRPC `h2,http/1.1` و برای WebSocket/HTTPUpgrade `http/1.1`.

مسیرهای `h2c://` بدون بافر استریم می‌شوند و سایتی که چنین مسیری دارد بدون فشرده‌سازی
سرو می‌شود، چون فشرده‌سازی استریم را نگه می‌دارد.

## گواهی‌ها

به‌صورت پیش‌فرض Caddy همهٔ گواهی‌ها را از Let's Encrypt می‌گیرد و حدود ۳۰ روز قبل از
انقضا تمدید می‌کند؛ لازم نیست چیز دیگری اجرا کنی. `list` و پنل نشان می‌دهند هر سایت
واقعاً از چه گواهی‌ای استفاده می‌کند و چند روز دیگر وقت دارد.

گواهی certbot که مال قبل از Caddy است ممکن است بی‌صدا تمدید نشود: حالت `standalone`
پورت ۸۰ را لازم دارد که حالا دست Caddy است، و حالت `nginx` به nginx نیاز دارد. `doctor`
این حالت را اعلام می‌کند و یک دستور گواهی را بدون قطعی به Caddy می‌سپارد:

</div>

```bash
sudo smart-caddy cert panel.example.com caddy
```

<div dir="rtl" align="right">

دستور `renew` همان لحظه گواهی تازه می‌گیرد. Caddy گواهی‌ها را در حافظه نگه می‌دارد،
پس حدود یک ثانیه ری‌استارت می‌شود؛ گواهی فعلی اول کنار گذاشته می‌شود و اگر گواهی جدید
نرسد برگردانده می‌شود. Let's Encrypt برای یک نام فقط ۵ تمدید در هفته اجازه می‌دهد.

## گزارش تغییرات

هر دستوری که چیزی را عوض می‌کند — از پنل یا ترمینال — یک مورد به
`/var/log/smart-caddy/activity.jsonl` اضافه می‌کند (۵۰۰ مورد آخر نگه داشته می‌شود):
زمان، چه کسی (`user@ip` از پنل)، دستور، خروجی و diff همهٔ فایل‌هایی که تغییر داد. پنل
آن را پایین صفحه نشان می‌دهد.

## اشتراک پورت ۴۴۳ با Xray

دو پروسه نمی‌توانند یک `IP:port` را همزمان bind کنند. ولی اگر Xray از قبل روی `:443`
باشد، خودش یک multiplexer کامل است: TLS را باز می‌کند و بر اساس SNI و ALPN و path
به پورت‌های محلی پخش می‌کند. Caddy **پشت** آن می‌رود.

</div>

```bash
sudo smart-caddy add shop.example.com 3000 --behind-xray
```

```
[ ok ] picked free loopback port 8082

== Done - one step left, in Xray ==
[ ok ] listening on 127.0.0.1:8082 (plain HTTP, PROXY protocol v2)

    SNI    shop.example.com
    ALPN   (leave empty)
    Path   /
    Dest   127.0.0.1:8082
    xver   2
```

<div dir="rtl" align="right">

همان جدول را در x-ui → inbound روی ۴۴۳ → Fallbacks → Add fallback وارد کن.

سه چیز باید هم‌راستا باشند، و اشتباه در هر کدام دقیقاً یک شکل دارد — دامنه‌ای که
هیچ‌وقت جواب نمی‌دهد:

- **HTTP ساده، نه HTTPS.** Xray قبل از فوروارد رمزگشایی می‌کند، پس سایت
  `http://domain:PORT` روی `127.0.0.1` است و گواهی ندارد.
- **PROXY protocol.** `xver 2` هر کانکشن را با یک هدر باینری شروع می‌کند. بدون
  listener wrapper متناظر، Caddy آن را یک درخواست خراب می‌بیند.
- **h2c.** یک fallback با `alpn h2` به‌صورت HTTP/2 **بدون رمز** می‌رسد، که یک
  listener ساده به‌صورت پیش‌فرض بلد نیست.

`--behind-xray` هر سه را می‌نویسد و بلاک listener را به global options اضافه می‌کند.
**گواهی مال inbound خود Xray است، نه Caddy** — Xray هندشیک را انجام می‌دهد، پس این
listener اصلاً TLS نمی‌بیند.

بعد `doctor` کانفیگ Xray را می‌خواند و می‌گوید آن ردیف fallback واقعاً هست یا نه:

</div>

```
== 7  Xray fallbacks ==
[ ok ] shop.example.com: Xray falls back to :8082
[warn] api.example.com: no Xray fallback points at :8083
       the domain will look dead until you add that row in x-ui
```

<div dir="rtl" align="right">

## پشت یک SNI proxy (مثل DNSGuard)

روی بعضی سرورها یک SNI proxy روی `:80`/`:443` نشسته که به کاربران خودش سرویس می‌دهد و
دامنه‌هایی را که خودش جواب نمی‌دهد، با هدر PROXY protocol روی یک پورت loopback به Caddy
تحویل می‌دهد. در این حالت در تنظیمات سراسری Caddy خط `https_port <n>` با عددی غیر از
۴۴۳ هست.

Smart Caddy این را تشخیص می‌دهد و دیگر `--behind-xray` پیشنهاد نمی‌کند. هر سایتی که
آنجا می‌سازد یک سایت HTTPS معمولی روی `127.0.0.1` است، و اگر پروکسی جلویی هدایت خودکار
Caddy را خاموش کرده باشد، یک هدایت صریح http → https هم اضافه می‌کند. برای **DNSGuard**
دامنه را خودش به `SNI_LOCAL_NAMES` در `/opt/dnsguard/.env` اضافه و آن را ری‌استارت می‌کند
(DNS چند ثانیه مکث می‌کند)؛ برای برنامه‌های دیگر می‌گوید کدام نام را باید به Caddy بدهند.
`doctor` هر سایتی را که هنوز تحویل داده نمی‌شود اعلام می‌کند.

### چه چیزی کار نمی‌کند

گذاشتن یک Caddy **معمولی** جلوی ریالیتی روی `:443`: وب‌سرور HTTP، TLS را باز می‌کند و
انتظار HTTP دارد، و VLESS/Reality هیچ‌کدام نیست. با ماژول caddy-l4 کار می‌کند - بخش
«ریالیتی روی ۴۴۳» را ببین.

## ریالیتی روی ۴۴۳

اینباند ریالیتی x-ui معمولاً پورت جدا لازم دارد، چون `:443` دست Caddy است. Smart Caddy
می‌تواند آن را کنار سایت‌ها روی `:443` بگذارد: یک برنامه روی `:443` فقط SNI را نگاه
می‌کند (اسم داخل TLS، بدون باز کردن چیزی) و اسم ریالیتی را دست‌نخورده به اینباند روی
loopback می‌دهد و بقیهٔ اسم‌ها را به Caddy.

آن برنامه یکی از این دو مسیریاب است:

- **DNSGuard**، وقتی خودش `:443` را جلوی Caddy دارد - اسم‌ها در `SNI_PASS` آن می‌روند.
- **مسیریاب SNI خود Caddy**، روی هر سرور دیگر: `smart-caddy sni enable` (یا دکمهٔ
  **روشن کن** در تب ریالیتی پنل) ماژول
  [caddy-l4](https://github.com/mholt/caddy-l4) را اضافه می‌کند، سایت‌ها را به
  `127.0.0.1:8444` / `:8081` می‌برد و Caddy پورت‌های `:443` و `:80` را از روی اسم پخش
  می‌کند. سایت‌ها همان آدرس و گواهی را دارند و IP واقعی بازدیدکننده را هم می‌بینند
  (PROXY protocol). یک برنامه، بدون نصب چیز دیگر؛ پکیج `caddy` نگه داشته (hold) می‌شود
  تا آپگرید apt ماژول را پاک نکند.

بعد خودش همگام می‌ماند: در x-ui یک اینباند ریالیتی با **Listen IP** `127.0.0.1`، یک
پورت آزاد و **SNI** مخصوص خودش بساز. حداکثر یک دقیقه بعد پنل برای آن SNI مسیر
می‌سازد و لینک اشتراک را روی پورت `443` می‌برد؛ SNI را عوض کنی یا اینباند را پاک
کنی، مسیر هم دنبالش می‌کند. چند ریالیتی کنار هم کار می‌کنند، هر کدام با SNI خودش.

</div>

```bash
sudo smart-caddy sni enable        # فقط جایی که خود Caddy پورت 443 را دارد
sudo smart-caddy reality           # همهٔ ریالیتی‌ها، روی 443 یا نه
sudo smart-caddy reality on443 8   # اینباند 8 را روی 127.0.0.1 و 443 ببر
sudo smart-caddy reality sync      # کاری که پنل هر دقیقه انجام می‌دهد
```

<div dir="rtl" align="right">

SNI را طوری انتخاب کن که یکی از سایت‌های خودت نباشد، جایی که کاربرانت هستند فیلتر
نباشد و ریالیتی دیگری از آن استفاده نکند. یک سایت بزرگ خارجی روی IP خودت نشانهٔ
شناخته‌شده‌ای برای شناسایی است؛ یک زیردامنهٔ خودت (با target ریالیتی روی Caddy) این
مشکل را ندارد.

## DNS

**زیردامنه‌هایت را روی DNS-only بگذار.** اگر ارائه‌دهنده‌ات تیک CDN یا «سرویس ابری»
دارد (ابر نارنجی Cloudflare، ابر آروان)، برای هر چیزی که Caddy سرو می‌کند خاموشش
کن: با روشن بودنش رکورد A آدرس CDN را برمی‌گرداند، چالش ACME هیچ‌وقت به سرور تو
نمی‌رسد، گواهی صادر نمی‌شود، و کل ترافیک تو — شامل کوکی نشست — از CDN رد می‌شود.

## عیب‌یابی

</div>

```bash
sudo smart-caddy doctor
```

<div dir="rtl" align="right">

| نشانه | علت معمول |
|---|---|
| `reload failed` | بلاکی `bind` ندارد ← `smart-caddy fixbind` |
| `permission denied` روی Caddyfile | مجوز/مالکیت خراب شده ← `smart-caddy repair` |
| مرورگر پاپ‌آپ ورود بومی نشان می‌دهد | بلاک `basic_auth` قدیمی ← `smart-caddy repair` |
| گواهی هیچ‌وقت صادر نمی‌شود | رکورد A جای دیگری است، CDN روشن است، یا پورت ۸۰ بسته است |
| گواهی certbot نزدیک انقضاست | تا وقتی Caddy پورت ۸۰ را دارد certbot نمی‌تواند تمدید کند ← `smart-caddy cert <domain> caddy` |
| `502 Bad Gateway` | بک‌اند بالا نیست، یا HTTPS حرف می‌زند و تو `host:port` ساده داده‌ای |
| پنل باز می‌شود ولی **آمار زنده خالی است** | هدر `Host` اجباری، محدودیت `--strict-path`، بافر شدن، یا نبود `versions 1.1` |
| `address already in use` | سرویس دیگری آن IP:port را گرفته — `ss -tnlp \| grep ':443'` |

### یک نکته دربارهٔ مجوز فایل‌ها

یونیت systemd مربوط به Caddy با کاربر غیرروت اجرا می‌شود، پس `/etc/caddy/Caddyfile`
باید برای آن خواندنی بماند. ویرایش آن فایل با `mktemp` + `mv` بی‌صدا مجوز و مالکیتش
را به `0600 root:root` عوض می‌کند و از آن به بعد هر reload با `permission denied`
شکست می‌خورد. این اسکریپت همیشه در جا ویرایش می‌کند و inode و مجوز و مالک را حفظ
می‌کند. اگر چیز دیگری از قبل این خرابی را کرده، `smart-caddy repair` درستش می‌کند.

## نیازمندی‌ها

`caddy`، `bash` ۴ به بالا، `systemd`، و `python3` برای پنل وب. توصیه‌شده:
`acl` (setfacl)، `dnsutils` (dig)، `netcat`. `setup` هرچه بتواند خودش نصب می‌کند.

## مجوز

MIT

</div>

</details>

<details open>
<summary><b>🇺🇸 English</b></summary>

Smart reverse proxy management for [Caddy](https://caddyserver.com), in one script.

Give it a domain → it writes the config, gets the certificate, validates, reloads.
If anything is wrong it **rolls back automatically**, so Caddy never goes down.

```
$ sudo smart-caddy add panel.example.com 54321

== Pre-flight checks ==
[ ok ] DNS -> 203.0.113.10
[ ok ] backend 127.0.0.1:54321 is reachable
[info] no certificate yet - Caddy will obtain one right after reload

== Applying ==
[ ok ] Caddy reloaded with no downtime.
[info] waiting for certificate issuance....
[ ok ] certificate issued, expires: Dec 20 14:02:11 2026 GMT

== Done ==
[ ok ] https://panel.example.com  ->  127.0.0.1:54321
```

---

## Install

```bash
curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh && sudo bash smart_caddy.sh
```

That URL always resolves to the newest release — no version number to update.

One file, one command. It installs Caddy itself if missing (apt, dnf, yum, pacman,
apk), inspects the machine, and asks only about what it cannot work out alone:

```
== Looking around ==
[ ok ] package manager: apt
[ ok ] Caddy is installed - v2.11.4
[ ok ] several addresses: 203.0.113.10 203.0.113.11
[warn] :443 is held by 'xray-linux-amd6'

       Caddy cannot share a port with another process. Your options:
         * if that is Xray, keep it and put sites behind its fallback:
               smart-caddy add <domain> <port> --behind-xray
         * if it is an old nginx/apache you no longer want, stop it first
         * or give Caddy its own IP on a multi-address host

== A few questions ==
  Address for Caddy (one of: 203.0.113.10 203.0.113.11) [203.0.113.10]:
  Email for Let's Encrypt (expiry notices) [admin@example.com]:
  Set up the web panel, so you can manage sites in a browser? [Y/n]
  Add your first site now? [y/N]
```

On a single-address host it never asks about addresses at all. The web panel's
source is embedded in the script, so there is nothing else to download.

> **Why download first instead of piping into bash?**
>
> `curl ... | bash` leaves no terminal to ask questions on, so every prompt would
> silently take its default. The script detects that and refuses rather than guess.
>
> `sudo bash -c "$(curl ...)"` passes the whole script as one command-line argument,
> and Linux caps a single argument at 128 KB. The script is bigger than that, so you
> get `Argument list too long`.
>
> `sudo bash <(curl ...)` fails too: sudo closes the `/dev/fd/63` that process
> substitution creates, so you get `/dev/fd/63: No such file or directory`.
>
> Saving the file and running it has none of these problems, keeps your terminal
> attached for the questions, and lets you read the script first if you like:
>
> ```bash
> curl -fsSL https://github.com/Plus98ir/Smart-Caddy/releases/latest/download/smart_caddy.sh -o smart_caddy.sh
> less smart_caddy.sh      # read it first
> sudo bash smart_caddy.sh
> ```

Already installed? Update in place:

```bash
sudo smart-caddy update
```

## Features

| | |
|---|---|
| **Never breaks your server** | `caddy validate` before every reload; any failure rolls back |
| **Automatic `bind`** | always emitted on multi-IP hosts, so no port collisions |
| **Permission-safe writes** | edits the Caddyfile in place, never clobbering mode or ownership |
| **Certificates on autopilot** | Caddy issues and renews every certificate itself; the panel shows days left and has a one-click **Renew** that puts the old cert back if anything fails |
| **Adopts your existing Caddy** | finds sites you wrote straight into the Caddyfile and imports them unchanged, so they show up in the panel |
| **Path routes** | send `/dns-query/*` or `/api/*` to a different backend than the rest of the site |
| **Reality on `:443`** | x-ui Reality inbounds share `:443` with your sites and are kept in step every minute - through DNSGuard, or **Caddy's own SNI router** (caddy-l4) on servers without it |
| **Real visitor IP behind Cloudflare** | Cloudflare's edges are trusted and `CF-Connecting-IP` is read from them only, so apps and Xray log the visitor, not Cloudflare |
| **Updates from the panel** | Settings → Update checks the latest release by content and installs it; sites stay up |
| **Xray configs behind Cloudflare** | route a secret path to an XHTTP / gRPC (`h2c://`) or WebSocket / HTTPUpgrade inbound, so the orange cloud hides the server's IP; the panel has a step-by-step guide |
| **Server identity** | give each server a name, an icon (flags work) and a colour: shown in the browser tab, favicon, header and sign-in page, so several panels never get mixed up |
| **Activity log** | every change, from the panel or the terminal: who, when, the output, and a diff of exactly which config lines changed |
| **Many backend types** | a local port, a TLS backend, a directory of files, another site, or a redirect |
| **Path-aware, not path-fragile** | records an app's base path without 404-ing the rest, so panel WebSockets keep working |
| **Behind another front proxy** | when an SNI proxy such as DNSGuard owns `:80`/`:443` and hands names to Caddy on loopback, sites are created behind it and the domain is registered with it for you |
| **Coexists with Xray** | `--behind-xray` sets up the loopback + PROXY protocol + h2c listener and verifies the fallback exists |
| **Web panel** | frosted-glass dark UI in tabs, Persian / English, real login page, PBKDF2 passwords, signed sessions, add / edit / remove sites, raw config editor |
| **Safe removal** | on delete, asks whether to keep the certificate (default: keep) |
| **`doctor`** | listeners, bind, DNS, permissions, certificates that cannot renew, WebSocket pitfalls, Xray fallbacks, recent errors |
| **`repair`** | fixes file permissions, stale auth blocks and missing HTTP version pins |

## Web panel

```bash
sudo smart-caddy panel                    # asks for the domain
sudo smart-caddy panel caddy.example.com  # or name it up front
```

A localhost-only service behind Caddy with TLS. List your sites, add them, **edit**
them, remove them, and run the diagnostics — all by calling the same CLI
underneath, so there is exactly one code path that writes config.

A dark frosted-glass interface, **Persian and English** (right-to-left in Persian),
organised in tabs, each with a title and a short explanation:

- **Overview** — Caddy's state, certificate counts, expiring certificates, and quick
  actions.
- **Sites** — every site with its backend, routes, and **how many days of SSL are
  left**, coloured as expiry gets close, with a **Renew** button.
- **Add / Edit site** — first *what are you putting online?* (a website, an x-ui
  panel, an Xray config through a CDN) with a step-by-step guide and **Fill in from
  x-ui** (panel port, base path and subscription read from x-ui); then one form with
  an explanation under every field: a **name** for the site, main backend, **path
  routes** (each with a ticked type: *Web / Sub*, *WebSocket / HTTPUpgrade* or
  *XHTTP / gRPC*; the leading `/` and trailing `*` are added for you), SSL certificate (Caddy,
  existing certbot, or self-signed), path prefix, Host header, admin-panel preset,
  plain HTTP, behind Xray.
- **Config** — edit any site's raw Caddyfile text. It is validated first and rolled
  back if Caddy rejects it, so a typo cannot take the server down.
- **Import** — sites written by hand into the Caddyfile, with one-click import. A
  domain defined twice gets a "keep this one" button.
- **Cloudflare CDN** — which Xray transports work behind Cloudflare and the exact
  steps in x-ui, here and in Cloudflare.
- **Diagnostics** and **Activity** — the full check, the output of every action,
  and each change with a coloured diff of the config files it touched.
- **Reality** — every x-ui Reality inbound, whether it is on `:443`, its share links,
  **Put on :443**, and on a server without DNSGuard the switch for Caddy's own SNI
  router. See [Reality on :443](#reality-on-443).
- **Settings** — **Update** (check the latest release and install it from the page)
  and the server's identity: a name, an icon and an accent colour, shown
  in the browser tab, favicon, header and sign-in page. Stored in
  `/etc/smart-caddy-brand.json`, untouched by updates.

It has a real sign-in page, not the browser's native credential box: passwords are
PBKDF2-HMAC-SHA256 (240k rounds) in `/etc/smart-caddy-panel.json` (mode 0600),
sessions are HMAC-signed cookies (`HttpOnly`, `SameSite=Strict`, `Secure` behind
HTTPS) that survive a restart, cross-origin POSTs are refused, and failed logins
back off exponentially after five tries.

Change the password from the terminal at any time:

```bash
sudo smart-caddy passwd                          # prompts twice
sudo smart-caddy passwd --password 'NewPass123'
sudo smart-caddy passwd newuser                  # change the username too
```

Changing it rotates the session key, so anyone already logged in is signed out.

Notes:

- The service binds `127.0.0.1` only. It authenticates, but speaks plain HTTP —
  keep Caddy in front of it rather than exposing the port.
- It runs as root, because it edits `/etc/caddy` and reloads the service.
- Every field is validated against a strict allowlist before reaching a
  subprocess, and commands are built as argv lists, never shell strings.

## Commands

```
setup                                    one command, start to finish
install [--ip <IP>] [--email <mail>]     just the system wiring
add <domain> <backend> [opts]            add a site
del <domain> [--keep-cert|--purge-cert]  remove a site
del-cert <domain>                        remove only the certificate
list                                     list sites and certificates
import [domain...] [--all|--list]        adopt sites already in the Caddyfile
import <domain> --replace                ... over a managed copy of the same domain
put <domain> <file>                      replace a site's config with your own text
cert <domain> caddy                      let Caddy issue and renew the certificate
renew <domain>                           get a fresh certificate now (rolls back on failure)
panel <domain> [--user u] [--port n]     install the web panel
panel status | panel remove [<domain>]   check or remove the web panel
passwd [user] [--password <p>]           change the panel password
doctor                                   full diagnostic
fixbind                                  add 'bind' to blocks missing it
repair                                   fix permissions and known upgrade issues
update [--force]                         install the latest release (also in the panel)
reality [status|sync|on443 <id>]         x-ui Reality inbounds on :443
sni [status|enable|disable]              Caddy's own SNI router (caddy-l4)
uninstall                                remove integration (certs kept)
```

Run `add` or `panel` with no arguments and they ask for what they need, validating
as they go.

### Backends

| You write | It means |
|---|---|
| `54321` | a port on this machine |
| `127.0.0.1:54321` | the same, spelled out |
| `https://127.0.0.1:27389` | a local app that serves TLS itself (pair with `--insecure`) |
| `10.0.0.5:9000` | a service on another machine |
| `/var/www/mysite` | serve files from that directory |
| `example.com` | proxy through to somebody else's site |
| `redirect:https://x.com` | send visitors there instead |

If you give a plain `host:port` but the backend actually speaks HTTPS, the script
detects it and offers to switch — that mismatch is the most common cause of a 502.

### `add` options

| Option | Effect |
|---|---|
| `--route <path>=<backend>` | send one path to another backend, e.g. `--route '/dns-query/*=8000'`. Repeatable. |
| `--replace` | overwrite an existing site in place (keeps its certificate and its Xray loopback port) |
| `--path <prefix>` | record the app's base path, shown in `list`. Repeatable. |
| `--strict-path` | additionally refuse everything outside those prefixes |
| `--behind-xray` | Xray owns `:443` and falls back to us |
| `--listen-port <n>` | pick the loopback port yourself (default: first free in 8081-8199) |
| `--panel` | preset for admin panels — implies `--insecure --no-buffer` |
| `--insecure` | don't verify the backend's TLS certificate |
| `--no-buffer` | stream responses through — live stats, SSE, log tails |
| `--host-header <v>` | force the `Host` header sent upstream (routers want `127.0.0.1`) |
| `--auto-cert` | Caddy issues and renews the certificate itself (recommended) |
| `--certbot` | use the existing certbot certificate |
| `--self-signed` | `tls internal` — Caddy's internal CA, for testing |
| `--no-tls` | plain HTTP |
| `--no-dns-check` | skip the A-record check |
| `-y, --yes` | non-interactive |

## Admin panels (x-ui, 3x-ui, Marzban, Hiddify)

These do three awkward things at once: they serve **HTTPS with a self-signed cert**
on localhost, they live under a **random base path**, and their dashboard streams
**live traffic counters**. Miss any one and you get a blank page, a 502, or a panel
that opens but never updates.

```bash
sudo smart-caddy add panel.example.com https://127.0.0.1:27389 \
    --panel --path /5wSobQvUFuNy4zBUcc
```

which generates:

```caddyfile
panel.example.com {
	bind 203.0.113.10
	encode zstd gzip

	# app base path: /5wSobQvUFuNy4zBUcc
	reverse_proxy https://127.0.0.1:27389 {
		transport http {
			tls_insecure_skip_verify
			versions 1.1
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Port {server_port}

		flush_interval -1
	}
}
```

Three details matter, and each one fails the same invisible way:

- **`flush_interval -1`** — Caddy's equivalent of nginx's `proxy_buffering off`.
  Without it the dashboard's live counters sit in a buffer and look frozen.
- **`versions 1.1`** — a TLS backend can negotiate HTTP/2 over ALPN, and HTTP/2 has
  no Upgrade mechanism, so WebSocket handshakes silently fail.
- **Never force the `Host` header on a panel.** Panels check the WebSocket's
  `Origin` against the `Host` they receive. Sending `Host: 127.0.0.1` while the
  browser sends `Origin: https://panel.example.com` makes that check fail, the
  WebSocket is refused, and the speed columns stay empty forever. `add` warns you
  if you try.

### Why `--path` does not restrict by default

`--path` records where the app lives; it does not block anything else. Admin panels
routinely serve their base path from one place and open their live-stats WebSocket
from the **site root**, so matching on the prefix and 404-ing the remainder produces
a panel that looks completely healthy while the live traffic columns stay
permanently blank — a genuinely hard bug to spot, because every page you click
works.

The app already 404s its own root, so the extra restriction usually buys nothing.
`--strict-path` restores the strict matcher if you really want it, with a warning.

## Already running Caddy?

Sites you wrote by hand live in the Caddyfile itself, where nothing can see them.
`setup` and `install` notice them and offer to import; you can also do it any time:

```bash
sudo smart-caddy import --list     # what is there
sudo smart-caddy import            # move them into sites.d
```

Each block moves **byte for byte** into `/etc/caddy/sites.d/<domain>.caddy`, so Caddy
serves exactly what it served before. The Caddyfile is backed up first, and the move is
validated and rolled back like any other change. Blocks with no domain name (`:80`, an
IP, `localhost`) and snippets stay where they are.

Imported sites are read back into the panel's form when they use directives it
understands — reverse proxies, path routes, files, redirects. Anything more exotic is
edited as raw text with **Config**.

## Path routes

One domain, several backends. A DNS-over-HTTPS server with its own admin page and a
public landing page, for example:

```bash
sudo smart-caddy add dns.example.com 8088 \
    --route '/dns-query/*=8000' --route '/panel*=8000'
```

Each route becomes a `handle` block, and the main backend takes everything else:

```caddyfile
	handle /dns-query/* {
		reverse_proxy 127.0.0.1:8000 { ... }
	}
	handle /panel* {
		reverse_proxy 127.0.0.1:8000 { ... }
	}
	handle {
		reverse_proxy 127.0.0.1:8088 { ... }
	}
```

## Xray configs behind Cloudflare

Put Caddy between Cloudflare and an Xray inbound: a ping of the domain returns
Cloudflare's IP, while traffic still leaves from this server. One domain carries
several configs, each on its own secret path.

| Transport | Through Cloudflare | Route type |
|---|---|---|
| XHTTP | yes (`packet-up` everywhere; stream modes need gRPC on in Cloudflare) | `h2c://127.0.0.1:PORT` |
| gRPC | yes (switch on Network → gRPC) | `h2c://127.0.0.1:PORT` |
| WebSocket, HTTPUpgrade | yes | `127.0.0.1:PORT` |
| Reality, TCP, Hysteria2, Shadowsocks | no — Cloudflare only carries HTTP | — |

1. In x-ui, the inbound listens on `127.0.0.1`, security **none** (TLS ends at
   Caddy — an inbound with its own TLS puts `pinnedPeerCertSha256` in the share
   link, and behind Cloudflare that pin never matches), a long random path, and
   your CDN domain as Host.
2. Add the site with the cloud still grey, a cover page as the main backend, and
   one route per config:

   ```bash
   sudo smart-caddy add cdn.example.com redirect:https://www.google.com \
       --route '/k8Jq2xVt*=h2c://127.0.0.1:3103' --route '/ws9Lp*=3305'
   ```

3. Once the certificate is issued, turn the cloud orange; SSL/TLS **Full
   (strict)**; keep *Always Use HTTPS* off so Caddy can renew over port 80.
4. Client: address = the domain or a clean Cloudflare IP, port 443, TLS, SNI and
   Host = the domain; ALPN `h2,http/1.1` for XHTTP/gRPC, `http/1.1` for
   WebSocket/HTTPUpgrade.

`h2c://` routes are streamed without buffering, and a site that has one is served
without compression, which would otherwise hold the stream back.

## Certificates

By default Caddy gets every certificate from Let's Encrypt and renews it about 30
days before expiry, with nothing else to run. `list` and the panel show what each
site actually uses and how long it has left.

A certbot certificate from before Caddy can quietly stop renewing: its `standalone`
mode needs port 80, which Caddy now holds, and its `nginx` mode needs nginx. `doctor`
flags that case, and one command hands the certificate to Caddy without downtime:

```bash
sudo smart-caddy cert panel.example.com caddy
```

`renew` fetches a fresh certificate on demand. Caddy keeps certificates in memory, so
it restarts Caddy for about a second; the current certificate is set aside first and
put back if no new one arrives. Let's Encrypt allows five renewals of the same name
per week.

## Activity log

Every command that changes something — from the panel or the terminal — appends one
entry to `/var/log/smart-caddy/activity.jsonl` (the last 500 are kept): when, who
(`user@ip` from the panel), the command, its output, and a unified diff of every file
it touched. The panel shows it at the bottom of the page.

## Sharing port 443 with Xray

Two processes cannot bind the same `IP:port`. But if Xray is already on `:443`, it
is also already a perfectly good multiplexer: it terminates TLS and dispatches by
SNI, ALPN and path to local ports. Caddy goes *behind* it.

```bash
sudo smart-caddy add shop.example.com 3000 --behind-xray
```

```
[ ok ] picked free loopback port 8082

== Done - one step left, in Xray ==
[ ok ] listening on 127.0.0.1:8082 (plain HTTP, PROXY protocol v2)

    SNI    shop.example.com
    ALPN   (leave empty)
    Path   /
    Dest   127.0.0.1:8082
    xver   2
```

Paste that into x-ui → the inbound on 443 → Fallbacks → Add fallback.

Three things have to line up, and getting any one wrong looks identical — a domain
that never responds:

- **Plain HTTP, not HTTPS.** Xray decrypts before forwarding, so the site is
  `http://domain:PORT` bound to `127.0.0.1` with no certificate.
- **PROXY protocol.** `xver 2` prefixes each connection with a binary header.
  Without the matching listener wrapper, Caddy reads it as a malformed request.
- **h2c.** An `alpn h2` fallback arrives as *cleartext* HTTP/2, which a plain
  listener does not speak by default.

`--behind-xray` writes all three and adds the listener stanza to the global options
block. **The certificate belongs to the Xray inbound, not to Caddy** — Xray does the
handshake, so this listener never sees one.

`doctor` then reads your Xray config and tells you whether the fallback row exists:

```
== 7  Xray fallbacks ==
[ ok ] shop.example.com: Xray falls back to :8082
[warn] api.example.com: no Xray fallback points at :8083
       the domain will look dead until you add that row in x-ui
```

## Behind an SNI proxy (DNSGuard and similar)

Some servers run an SNI proxy on `:80`/`:443` that serves its own clients and hands
the names it does not handle to Caddy on a loopback port, with a PROXY protocol
header. Caddy's global options then contain `https_port <n>` with `n` other than 443.

Smart Caddy detects that and stops suggesting `--behind-xray`. Every site it creates
there is an ordinary HTTPS site bound to `127.0.0.1`, with an explicit http → https
redirect when the front proxy has turned Caddy's own redirect off. For **DNSGuard** it
also adds the domain to `SNI_LOCAL_NAMES` in `/opt/dnsguard/.env` and restarts it (DNS
pauses for a few seconds); for anything else it tells you which name to forward.
`doctor` lists any site the front proxy does not hand over yet.

### What does not work

Putting a *stock* Caddy in front of Reality on `:443`: an HTTP server terminates TLS
and expects HTTP, and VLESS/Reality is neither. With the caddy-l4 module it works -
see [Reality on :443](#reality-on-443).

## Reality on :443

An x-ui Reality inbound normally needs a port of its own, because Caddy holds
`:443`. Smart Caddy can put it on `:443` next to your sites: something on `:443`
reads only the SNI (the name in the TLS hello, without decrypting anything) and
hands a Reality name, untouched, to the inbound on loopback, and every other name
to Caddy.

That "something" is one of two routers:

- **DNSGuard**, when it already owns `:443` in front of Caddy - the names go into
  its `SNI_PASS`.
- **Caddy's own SNI router**, on any other server: `smart-caddy sni enable` (or the
  **Turn it on** button on the panel's Reality tab) adds the
  [caddy-l4](https://github.com/mholt/caddy-l4) module, moves the sites to
  `127.0.0.1:8444` / `:8081` and lets Caddy route `:443` and `:80` by name. The
  sites keep their addresses and certificates, and still see the visitor's IP
  (PROXY protocol). One process, nothing else to install; the `caddy` package is
  held so an apt upgrade cannot drop the module.

Then it keeps itself in step: in x-ui make a Reality inbound with **Listen IP**
`127.0.0.1`, any free port, and its own **SNI**. Within a minute the panel gives that
SNI its route and points the share link at port `443`; change the SNI or delete the
inbound and the route follows. Several Realities work side by side, one SNI each.

```bash
sudo smart-caddy sni enable        # only where Caddy holds :443 itself
sudo smart-caddy reality           # every Reality inbound, on :443 or not
sudo smart-caddy reality on443 8   # move inbound 8 to 127.0.0.1 and onto :443
sudo smart-caddy reality sync      # what the panel does every minute
```

Pick an SNI that is not one of your own sites, not blocked where your users are,
and not used by another Reality. A big foreign site on your own IP is a known
detection signal; a subdomain of your own (with Reality's target pointing at Caddy)
avoids it.

## DNS

**Put your subdomains on DNS-only.** If your provider has a CDN or "cloud proxy"
toggle (Cloudflare's orange cloud, ArvanCloud's ابر), leave it off for anything
Caddy serves: with it on, the A record returns the CDN's IP, the ACME challenge
never reaches your server, no certificate is issued, and all your traffic — session
cookies included — passes through the CDN.

## Troubleshooting

```bash
sudo smart-caddy doctor
```

| Symptom | Usual cause |
|---|---|
| `reload failed` | a block has no `bind` → `smart-caddy fixbind` |
| `permission denied` on the Caddyfile | mode/ownership clobbered → `smart-caddy repair` |
| Browser shows a native login popup | an old `basic_auth` block → `smart-caddy repair` |
| Certificate never issued | A record points elsewhere, CDN proxy on, or port 80 closed |
| certbot certificate about to expire | certbot cannot renew while Caddy holds :80 → `smart-caddy cert <domain> caddy` |
| `502 Bad Gateway` | backend down, or it speaks HTTPS and you gave a plain `host:port` |
| Panel loads but **live stats stay empty** | a forced `Host` header, a `--strict-path` restriction, buffering, or a missing `versions 1.1` |
| `address already in use` | another service holds that IP:port — `ss -tnlp \| grep ':443'` |

### A note on file permissions

Caddy's systemd unit runs as an unprivileged user, so `/etc/caddy/Caddyfile` must
stay readable by it. Editing that file with `mktemp` + `mv` silently replaces its
mode and ownership with `0600 root:root`, and every later reload fails with
`permission denied`. This script always edits in place, preserving inode, mode and
owner. If something else already did the damage, `smart-caddy repair` fixes it.

## Requirements

`caddy`, `bash` 4+, `systemd`, and `python3` for the web panel. Recommended:
`acl` (setfacl), `dnsutils` (dig), `netcat`. `setup` installs what it can.

## License

MIT

</details>
