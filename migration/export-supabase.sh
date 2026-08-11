#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  تصدير بيانات مَلَفّي من Supabase قبل الترحيل إلى خادم الرياض.
#
#  يُخرج ثلاثة ملفات JSON: حالات المعلمين، والاشتراكات، والحسابات.
#  لا يحذف شيئًا من Supabase — التصدير آمن ويمكن تكراره.
#
#  التشغيل:
#    export SUPABASE_URL="https://xxxx.supabase.co"
#    export SUPABASE_SERVICE_ROLE_KEY="ضعه في المتغيّر لا في الملف"
#    bash migration/export-supabase.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

: "${SUPABASE_URL:?اضبط SUPABASE_URL أولًا}"
: "${SUPABASE_SERVICE_ROLE_KEY:?اضبط SUPABASE_SERVICE_ROLE_KEY أولًا}"

OUT="migration/dump-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
AUTH=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")

# حالات المعلمين تُسحب على دفعات: صفٌّ واحد قد يبلغ عدة ميغابايت
# لأن صور الشواهد مخزَّنة داخله بترميز base64.
echo "── حالات المعلمين ──"
PAGE=0; SIZE=50; : > "$OUT/app_state.json"
while :; do
  FROM=$((PAGE*SIZE)); TO=$((FROM+SIZE-1))
  BODY=$(curl -sS "${AUTH[@]}" -H "Range: $FROM-$TO" \
    "$SUPABASE_URL/rest/v1/app_state?select=*&order=user_id")
  COUNT=$(printf '%s' "$BODY" | python -c "import sys,json;print(len(json.load(sys.stdin)))")
  [ "$COUNT" = "0" ] && break
  printf '%s\n' "$BODY" >> "$OUT/app_state.json"
  echo "   صفحة $((PAGE+1)): $COUNT صفًّا"
  [ "$COUNT" -lt "$SIZE" ] && break
  PAGE=$((PAGE+1))
done

echo "── الاشتراكات ──"
curl -sS "${AUTH[@]}" "$SUPABASE_URL/rest/v1/subscriptions?select=*" > "$OUT/subscriptions.json"

# الحسابات تأتي من واجهة الإدارة لا من REST. كلمات المرور لا تُصدَّر
# ولا يمكن تصديرها — سيُطلب من كل معلّم تعيين كلمة مرور جديدة، أو
# تُرسل روابط إعادة تعيين بعد الترحيل.
echo "── الحسابات ──"
curl -sS "${AUTH[@]}" "$SUPABASE_URL/auth/v1/admin/users?per_page=1000" > "$OUT/users.json"

echo
echo "✔ التصدير في: $OUT"
python - "$OUT" <<'PY'
import json,sys,os,glob
d=sys.argv[1]
def count(p,key=None):
    try:
        raw=open(p,encoding='utf-8').read().strip()
        if not raw: return 0
        n=0
        for line in raw.splitlines():
            if not line.strip(): continue
            v=json.loads(line)
            n+=len(v if isinstance(v,list) else v.get(key or 'users',[]))
        return n
    except Exception as e: return 'تعذّر: '+str(e)
print('   حالات:', count(os.path.join(d,'app_state.json')))
print('   اشتراكات:', count(os.path.join(d,'subscriptions.json')))
print('   حسابات:', count(os.path.join(d,'users.json'),'users'))
size=sum(os.path.getsize(f) for f in glob.glob(os.path.join(d,'*.json')))
print('   الحجم: %.1f ميغابايت' % (size/1048576))
PY
echo
echo "الخطوة التالية: migration/import-postgres.sh على خادم الرياض"
