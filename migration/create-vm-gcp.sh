#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  إنشاء خادم مَلَفّي على Google Cloud — الدمام me-central2
#
#  التشغيل من جهازك بعد تثبيت gcloud وتسجيل الدخول:
#    gcloud auth login
#    PROJECT_ID=مشروعك bash migration/create-vm-gcp.sh
#
#  لا يضع أي مفتاح. الدخول للخادم عبر gcloud compute ssh، وهو
#  يولّد مفتاحك ويرفعه تلقائيًا فلا مفتاح يُنزَّل ولا يُفقد.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

: "${PROJECT_ID:?اضبط PROJECT_ID أولًا}"
REGION=me-central2                 # الدمام
ZONE="${ZONE:-me-central2-a}"
NAME="${NAME:-malafi}"
MACHINE="${MACHINE:-e2-standard-2}"   # 2 vCPU · 8 GB
DISK_GB=100

gcloud config set project "$PROJECT_ID" >/dev/null
echo "المشروع: $PROJECT_ID | المنطقة: $REGION | النطاق: $ZONE"

echo "── تفعيل الخدمة ──"
gcloud services enable compute.googleapis.com --quiet

# عنوان ثابت. بدونه يعطي Google عنوانًا مؤقتًا يتغيّر عند كل إيقاف
# وتشغيل، فينكسر سجل A في الدومين بلا سبب ظاهر.
echo "── العنوان الثابت ──"
if ! gcloud compute addresses describe "$NAME-ip" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$NAME-ip" --region="$REGION" --quiet
fi
IP="$(gcloud compute addresses describe "$NAME-ip" --region="$REGION" --format='value(address)')"

echo "── قواعد الجدار ──"
# Google قد ينشئ default-allow-http/https تلقائيًا؛ ننشئها إن غابت فقط.
for R in "http:80" "https:443"; do
  N="${R%%:*}"; P="${R##*:}"
  gcloud compute firewall-rules describe "allow-$N" >/dev/null 2>&1 || \
    gcloud compute firewall-rules create "allow-$N" \
      --allow="tcp:$P" --target-tags="$N-server" \
      --source-ranges=0.0.0.0/0 --quiet
done

echo "── الخادم ──"
if gcloud compute instances describe "$NAME" --zone="$ZONE" >/dev/null 2>&1; then
  echo "   موجود مسبقًا — لن يُعاد إنشاؤه"
else
  gcloud compute instances create "$NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size="${DISK_GB}GB" \
    --boot-disk-type=pd-balanced \
    --address="$IP" \
    --tags=http-server,https-server \
    --quiet
fi

echo
echo "════════════════════════════════════════════════════════"
echo " ✔ الخادم جاهز"
echo
echo " عنوان IP الثابت (ضعه في سجل A عند T2):"
echo "   $IP"
echo
echo " الدخول:"
echo "   gcloud compute ssh $NAME --zone=$ZONE"
echo
echo " ثم على الخادم:"
echo "   sudo bash setup-server.sh"
echo "════════════════════════════════════════════════════════"
echo
echo " إن رفض النطاق نوع الجهاز، اعرض المتاح:"
echo "   gcloud compute machine-types list --filter='zone~me-central2'"
