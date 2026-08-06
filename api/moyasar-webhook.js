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
    const paymentId = data.id;
    if (!paymentId) {
      res.status(400).json({ message: 'no payment id' });
      return;
    }

    // تحقق ثانٍ وهو الحاسم: نسأل مويسر مباشرة عن هذه الدفعة
    const vr = await fetch('https://api.moyasar.com/v1/payments/' + encodeURIComponent(paymentId), {
      headers: { Authorization: 'Basic ' + Buffer.from(MOYASAR_SECRET + ':').toString('base64') }
    });
    const payment = await vr.json();
    if (!vr.ok) {
      console.error('verify failed', payment);
      res.status(502).json({ message: 'verify failed' });
      return;
    }
    if (payment.status !== 'paid') {
      // ليست فشلًا في المعالجة، فلا نطلب من مويسر إعادة المحاولة
      res.status(200).json({ ok: true, ignored: payment.status });
      return;
    }

    const userId = payment.metadata && payment.metadata.user_id;
    if (!userId) {
      console.error('payment without user_id', paymentId);
      res.status(200).json({ ok: true, ignored: 'no user' });
      return;
    }

    // نمدّد سنة من اليوم، أو من نهاية الاشتراك الحالي إن كان ما زال ساريًا
    let base = Date.now();
    try {
      const cur = await fetch(
        SUPA_URL + '/rest/v1/subscriptions?select=expires_at&user_id=eq.' + userId,
        { headers: { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY } }
      );
      const rows = await cur.json();
      const exp = rows && rows[0] && rows[0].expires_at;
      if (exp && new Date(exp).getTime() > base) base = new Date(exp).getTime();
    } catch (e) { /* نكمل من اليوم */ }

    const up = await fetch(SUPA_URL + '/rest/v1/subscriptions?user_id=eq.' + userId, {
      method: 'PATCH',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: 'Bearer ' + SERVICE_KEY,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal'
      },
      body: JSON.stringify({
        status: 'active',
        plan: 'annual',
        expires_at: new Date(base + YEAR_MS).toISOString(),
        provider: 'moyasar',
        provider_ref: paymentId,
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
