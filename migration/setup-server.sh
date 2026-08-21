#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  تجهيز خادم مَلَفّي — Ubuntu 24.04 (SCCC · الرياض، أو أي مزوّد آخر)
#
#  التشغيل على الخادم:  sudo bash setup-server.sh
#
#  لا يضع أي مفتاح ولا كلمة سرّ. كلمة مرور قاعدة البيانات تُولَّد
#  عشوائيًا وتُطبع مرة واحدة — انسخها فورًا.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "شغّله بـ sudo"; exit 1; }

DOMAIN="${DOMAIN:-malafi.sa}"
DB_NAME=malaffi
DB_USER=malaffi

echo "── تحديث النظام ──"
apt-get update -qq && apt-get upgrade -y -qq

echo "── الحزم ──"
apt-get install -y -qq nginx postgresql postgresql-contrib \
  php8.3-fpm php8.3-pgsql php8.3-mbstring php8.3-xml php8.3-curl php8.3-zip \
  composer certbot python3-certbot-nginx ufw unzip git

echo "── قاعدة البيانات ──"
DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE $DB_NAME' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='$DB_NAME')\gexec
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$DB_USER') THEN
    CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS';
  ELSE
    ALTER ROLE $DB_USER PASSWORD '$DB_PASS';
  END IF;
END \$\$;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
SQL

# القاعدة لا تستمع إلا محليًا: التطبيق على الخادم نفسه فلا داعي
# لفتحها على الشبكة، وهذا يغلق أوسع باب هجوم.
sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" /etc/postgresql/*/main/postgresql.conf
systemctl restart postgresql

echo "── الجدار الناري ──"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

# ufw أعلاه هو جدار الخادم. ولمزوّدي السحابة جدار ثانٍ على مستوى الشبكة
# (مجموعة الأمان في SCCC، وVPC في Google) — تأكّد أن 80 و443 مفتوحان فيه
# أيضًا، وإلا بقي الموقع محجوبًا رغم أن كل شيء على الخادم سليم.

echo "── nginx ──"
mkdir -p /var/www/malaffi/public
cat >/etc/nginx/sites-available/malaffi <<NGINX
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/malaffi/public;
    index index.html index.php;

    client_max_body_size 25M;   # الشواهد تُرفع بترميز base64 فتكبر

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
    location ~ /\.(?!well-known) { deny all; }
}
NGINX
ln -sf /etc/nginx/sites-available/malaffi /etc/nginx/sites-enabled/malaffi
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "── النسخ الاحتياطية اليومية ──"
mkdir -p /var/backups/malaffi
cat >/etc/cron.daily/malaffi-backup <<'CRON'
#!/bin/sh
# نسخة يومية تبقى ١٤ يومًا، على الخادم نفسه داخل المملكة.
D=$(date +%Y%m%d)
sudo -u postgres pg_dump malaffi | gzip > /var/backups/malaffi/db-$D.sql.gz
find /var/backups/malaffi -name 'db-*.sql.gz' -mtime +14 -delete
CRON
chmod +x /etc/cron.daily/malaffi-backup

echo
echo "════════════════════════════════════════════════════════"
echo " ✔ الخادم جاهز"
echo
echo " كلمة مرور قاعدة البيانات (تُطبع مرة واحدة — انسخها الآن):"
echo "   $DB_PASS"
echo
echo " ضعها في .env:"
echo "   DATABASE_URL=postgres://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME"
echo
echo " الخطوة التالية بعد أن يشير الدومين لهذا الخادم:"
echo "   certbot --nginx -d $DOMAIN -d www.$DOMAIN"
echo "════════════════════════════════════════════════════════"
