<div align="center">

# smart-caddy

[English](README.md) · **فارسی**

مدیریت هوشمند reverse proxy روی [Caddy](https://caddyserver.com)، در یک اسکریپت.

</div>

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
curl -fsSL https://raw.githubusercontent.com/<you>/smart-caddy/main/smart_caddy.sh -o smart_caddy.sh
sudo bash smart_caddy.sh
```

<div dir="rtl" align="right">

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

> **`curl ... | bash` کار نمی‌کند.** وقتی ورودی یک لوله باشد، ترمینالی برای سؤال
> پرسیدن نمی‌ماند و هر prompt بی‌صدا مقدار پیش‌فرض را برمی‌دارد. اسکریپت این را
> تشخیص می‌دهد و به‌جای حدس زدن امتناع می‌کند. همان شکل دو مرحله‌ای بالا را استفاده
> کن، یا `sudo bash <(curl -fsSL <url>) setup`.

## چه کارهایی می‌کند

| | |
|---|---|
| **هیچ‌وقت سرور را خراب نمی‌کند** | قبل از هر reload یک `caddy validate`؛ هر خطا = برگشت خودکار |
| **`bind` خودکار** | روی سرورهای چند‌IP همیشه می‌نویسدش، پس تصادم پورت پیش نمی‌آید |
| **نوشتن امن فایل** | Caddyfile را در جا ویرایش می‌کند، بدون خراب کردن مجوز و مالکیت |
| **گواهی هوشمند** | گواهی موجود certbot یا Caddy را دوباره استفاده می‌کند؛ فقط وقتی هیچ‌کدام نباشد درخواست جدید می‌دهد |
| **انواع بک‌اند** | پورت محلی، بک‌اند TLS، پوشهٔ فایل، سایت دیگر، یا ریدایرکت |
| **آگاه از path، ولی شکننده نه** | مسیر پایهٔ اپ را ثبت می‌کند بدون اینکه بقیه را ۴۰۴ کند، پس WebSocket پنل‌ها سالم می‌ماند |
| **همزیستی با Xray** | `--behind-xray` لیسنر loopback + PROXY protocol + h2c را می‌چیند و وجود fallback را چک می‌کند |
| **پنل وب** | صفحهٔ ورود واقعی، رمز PBKDF2، نشست امضاشده، افزودن / **ویرایش** / حذف سایت |
| **حذف امن** | موقع حذف می‌پرسد گواهی بماند یا برود (پیش‌فرض: بماند) |
| **`doctor`** | پورت‌ها، bind، DNS، مجوزها، تله‌های WebSocket، fallbackهای Xray، خطاهای اخیر |
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
panel <domain> [--user u] [--port n]     نصب پنل وب
panel status | panel remove [<domain>]   بررسی یا حذف پنل وب
passwd [user] [--password <p>]           تغییر رمز پنل
doctor                                   تشخیص کامل
fixbind                                  افزودن bind به بلاک‌های بدون bind
repair                                   رفع مجوزها و مشکلات شناخته‌شدهٔ آپگرید
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
| `--path <prefix>` | مسیر پایهٔ اپ را ثبت کن، در `list` نشان داده می‌شود. قابل تکرار. |
| `--strict-path` | علاوه بر آن، هر چیزی بیرون از این مسیرها را رد کن |
| `--behind-xray` | Xray صاحب `:443` است و به ما fallback می‌کند |
| `--listen-port <n>` | پورت loopback را خودت انتخاب کن (پیش‌فرض: اولین آزاد در ۸۰۸۱–۸۱۹۹) |
| `--panel` | پیش‌تنظیم پنل‌های مدیریتی — یعنی `--insecure --no-buffer` |
| `--insecure` | گواهی TLS بک‌اند را بررسی نکن |
| `--no-buffer` | پاسخ‌ها را مستقیم پخش کن — آمار زنده، SSE، دنبال کردن لاگ |
| `--host-header <v>` | هدر `Host` ارسالی به بک‌اند را اجبار کن (روترها `127.0.0.1` می‌خواهند) |
| `--auto-cert` | حتی با وجود گواهی certbot، گواهی جدید بگیر |
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
	tls /etc/letsencrypt/live/panel.example.com/fullchain.pem /etc/letsencrypt/live/panel.example.com/privkey.pem

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

### چه چیزی کار نمی‌کند

گذاشتن یک Caddy معمولی **جلوی** Xray روی `:443`. Caddy یک وب‌سرور HTTP است: TLS را
باز می‌کند و انتظار HTTP دارد، و VLESS/Reality هیچ‌کدام نیست. (اگر inbound از نوع
WebSocket یا xHTTP باشد، آن HTTP است و Caddy می‌تواند جلویش بنشیند.) برای مسیریابی
واقعی بر اساس SNI با Caddy در جلو، به پلاگین `caddy-l4` و build با `xcaddy` نیاز
داری؛ Xray همین را بدون هیچ چیز اضافه انجام می‌دهد.

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
