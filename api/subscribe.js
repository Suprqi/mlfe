// إنشاء فاتورة اشتراك في مويسر وإعادة رابط الدفع.
// المفتاح السري خادمي فقط ولا يظهر في المتصفح إطلاقًا.
const { requireUser } = require('./_auth');

const PRICE_SAR = 100;
const MOYASAR_API = 'https://api.moyasar.com/v1/invoices';

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ message: 'طريقة غير مسموحة' });
    return;
  }

  const secret = process.env.MOYASAR_SECRET_KEY;
  if (!secret) {
    res.status(500).json({ message: 'بوابة الدفع غير مهيأة على الخادم' });
    return;
  }

  // لا نبيع لمجهول: نحتاج الحساب لنعرف لمن نفعّل الاشتراك
  const gate = await requireUser(req);
  if (!gate.ok) {
    res.status(401).json({ message: gate.message });
    return;
  }

  try {
    const origin = 'https://' + (req.headers['x-forwarded-host'] || req.headers.host);
    const r = await fetch(MOYASAR_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Basic ' + Buffer.from(secret + ':').toString('base64')
      },
      body: JSON.stringify({
        // مويسر يحسب بالهللات
        amount: PRICE_SAR * 100,
        currency: 'SAR',
        description: 'اشتراك مَلَفّي السنوي — ' + (gate.user.email || ''),
        callback_url: origin + '/?paid=1',
        // نربط الفاتورة بالمستخدم لنفعّل اشتراكه عند تأكيد الدفع
        metadata: { user_id: gate.user.id, email: gate.user.email || '' }
      })
    });

    const data = await r.json();
    if (!r.ok || !data.url) {
      console.error('moyasar invoice failed', data);
      res.status(502).json({ message: (data && data.message) || 'تعذّر إنشاء فاتورة الدفع' });
      return;
    }

    res.status(200).json({ url: data.url, id: data.id });
  } catch (e) {
    console.error(e);
    res.status(502).json({ message: 'تعذّر الاتصال ببوابة الدفع، حاول مرة أخرى' });
  }
};
