<div align="center">

# Smart-Caddy

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
| **گزارش تغییرات** | همهٔ تغییرات، چه از پنل چه از ترمینال: چه کسی، کی، خروجی، و diff دقیق خطوطی از کانفیگ که عوض شد |
| **انواع بک‌اند** | پورت محلی، بک‌اند TLS، پوشهٔ فایل، سایت دیگر، یا ریدایرکت |
| **آگاه از path، ولی شکننده نه** | مسیر پایهٔ اپ را ثبت می‌کند بدون اینکه بقیه را ۴۰۴ کند، پس WebSocket پنل‌ها سالم می‌ماند |
| **پشت یک پروکسی دیگر** | وقتی یک SNI proxy مثل DNSGuard پورت‌های `:80`/`:443` را دارد و دامنه‌ها را روی loopback به Caddy می‌دهد، سایت‌ها پشت آن ساخته می‌شوند و دامنه خودکار در آن ثبت می‌شود |
| **همزیستی با Xray** | `--behind-xray` لیسنر loopback + PROXY protocol + h2c را می‌چیند و وجود fallback را چک می‌کند |
| **پنل وب** | فارسی / انگلیسی، صفحهٔ ورود واقعی، رمز PBKDF2، نشست امضاشده، افزودن / **ویرایش** / حذف سایت، ویرایشگر متن خام کانفیگ |
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

چه چیزهایی نشان می‌دهد و چه کار می‌کند:

- **فارسی و انگلیسی** با دکمهٔ تغییر زبان (در فارسی راست‌به‌چپ).
- هر سایت با مقصد، مسیرها و **تعداد روزهای باقی‌ماندهٔ SSL** که با نزدیک شدن انقضا
  رنگش عوض می‌شود، به‌همراه دکمهٔ **تمدید**.
- یک فرم برای افزودن یا ویرایش سایت، با توضیح زیر هر فیلد: مقصد اصلی، **مسیرها**،
  پیشوند مسیر، هدر Host، **گواهی SSL** (Caddy، certbot موجود، یا خودامضا)، پیش‌تنظیم
  پنل مدیریتی، HTTP ساده، پشت Xray.
- **کانفیگ**: متن خام Caddyfile هر سایت را ویرایش کن. اول بررسی می‌شود و اگر Caddy
  قبول نکند برمی‌گردد، پس یک اشتباه تایپی سرور را از کار نمی‌اندازد.
- **پیداشده در Caddyfile**: سایت‌هایی که دستی در Caddyfile نوشته شده‌اند، با وارد
  کردن تک‌کلیکی. دامنه‌ای که دو بار تعریف شده دکمهٔ «همین را نگه دار» می‌گیرد.
- **عیب‌یابی و خروجی** و **گزارش تغییرات** پایین صفحه. هر مورد گزارش باز می‌شود و
  خروجی دستور و diff رنگی فایل‌های کانفیگی را که عوض کرد نشان می‌دهد.

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
