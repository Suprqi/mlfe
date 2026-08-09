// تفعيل الاشتراك بعد نجاح الدفع.
// مويسر ينادي هذه النقطة، لكننا لا نصدّق ما يصلنا: نعيد سؤال مويسر عن حالة
// الدفعة بمفتاحنا السري، لأن أي جهة تستطيع إرسال طلب مزوّر لهذا الرابط.
const SUPA_URL = process.env.SUPABASE_URL || 'https://athqvuwpqellyqoyhdwx.supabase.co';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const MOYASAR_SECRET = process.env.MOYASAR_SECRET_KEY;
const WEBHOOK_TOKEN = process.env.MOYASAR_WEBHOOK_TOKEN;

const YEAR_MS = 365 * 24 * 60 * 60 * 1000;

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ message: 'method not allowed' });
    return;
  }
  if (!SERVICE_KEY || !MOYASAR_SECRET) {
    console.error('webhook not configured');
    res.status(500).json({ message: 'not configured' });
    return;
  }

  try {
    const body = req.body || {};

    // تحقق أول: الرمز المتفق عليه مع مويسر، إن ضُبط
    if (WEBHOOK_TOKEN && body.secret_token !== WEBHOOK_TOKEN) {
      res.status(401).json({ message: 'bad token' });
      return;
    }

    const data = body.data || body;
    const objectId = data.id;
    if (!objectId) {
      res.status(400).json({ message: 'no id' });
      return;
    }

    // تحقق ثانٍ وهو الحاسم: نسأل مويسر مباشرة عن هذا الكائن.
    // نحن ننشئ فواتير لا دفعات مباشرة، ومويسر يرسل أحداثًا على المستويين،
    // فسؤال نقطة الدفعات وحدها كان يفشل عند حدث الفاتورة فيردّ ٥٠٢ ويعيد
    // مويسر المحاولة بلا نهاية ولا يُفعَّل الاشتراك أبدًا.
    const auth = 'Basic ' + Buffer.from(MOYASAR_SECRET + ':').toString('base64');
    let obj = null;
    for (const path of ['/v1/payments/', '/v1/invoices/']) {
      const r = await fetch('https://api.moyasar.com' + path + encodeURIComponent(objectId), {
        headers: { Authorization: auth }
      });
      if (r.ok) { obj = await r.json(); break; }
    }
    if (!obj) {
      console.error('verify failed', objectId);
      res.status(502).json({ message: 'verify failed' });
      return;
    }
    if (obj.status !== 'paid') {
      // ليست فشلًا في المعالجة، فلا نطلب من مويسر إعادة المحاولة
      res.status(200).json({ ok: true, ignored: obj.status });
      return;
    }

    const userId = obj.metadata && obj.metadata.user_id;
    if (!userId) {
      console.error('paid object without user_id', objectId);
      res.status(200).json({ ok: true, ignored: 'no user' });
      return;
    }

    // نمدّد سنة من اليوم، أو من نهاية الاشتراك الحالي إن كان ما زال ساريًا.
    // ومويسر يعيد الإشعار عند أي تعثّر وقد تكرّره الشبكة، فبلا فحص المرجع
    // كانت كل إعادة إرسال تمنح سنة إضافية بلا مقابل.
    let base = Date.now();
    const cur = await fetch(
      SUPA_URL + '/rest/v1/subscriptions?select=expires_at,provider_ref&user_id=eq.' + userId,
      { headers: { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY } }
    );
    if (!cur.ok) {
      // لا نُفعّل ونحن نجهل ما سبق: منح سنة مكرّرة أسوأ من تأخّر يعيد مويسر بعده
      console.error('read subscription failed', await cur.text());
      res.status(502).json({ message: 'read failed' });
      return;
    }
    const rows = await cur.json();
    const row = rows && rows[0];
    if (row && row.provider_ref === objectId) {
      res.status(200).json({ ok: true, already: true });
      return;
    }
    if (row && row.expires_at && new Date(row.expires_at).getTime() > base) {
      base = new Date(row.expires_at).getTime();
    }

    // إدراج مدمج لا تعديل: التعديل لا يطابق شيئًا إن لم يكن للمعلّم صفّ بعد،
    // فيردّ نجاحًا ولا يُفعَّل شيء — يدفع المعلّم ولا يحصل على اشتراكه.
    const up = await fetch(SUPA_URL + '/rest/v1/subscriptions', {
      method: 'POST',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: 'Bearer ' + SERVICE_KEY,
        'Content-Type': 'application/json',
        Prefer: 'resolution=merge-duplicates,return=minimal'
      },
      body: JSON.stringify({
        user_id: userId,
        status: 'active',
        plan: 'annual',
        expires_at: new Date(base + YEAR_MS).toISOString(),
        provider: 'moyasar',
        provider_ref: objectId,
        updated_at: new Date().toISOString()
      })
    });

    if (!up.ok) {
      const t = await up.text();
      console.error('activate failed', t);
      res.status(500).json({ message: 'activate failed' });
      return;
    }

    res.status(200).json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ message: 'error' });
  }
};
