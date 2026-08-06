// نقطة نهاية وسيطة: تستقبل الطلب من المتصفح وتضيف مفتاح Anthropic خادميًا.
// المفتاح يُقرأ من متغير بيئة ANTHROPIC_API_KEY ولا يظهر أبدًا في المتصفح.
const { requireUser } = require('./_auth');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ message: 'طريقة غير مسموحة' });
    return;
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    res.status(500).json({ message: 'مفتاح خدمة الذكاء الاصطناعي غير مهيأ على الخادم' });
    return;
  }

  // بدون هذا الفحص كانت النقطة مفتوحة للعالم: أي شخص يعرف الرابط يستهلك الرصيد
  const gate = await requireUser(req);
  if (!gate.ok) {
    res.status(401).json({ message: gate.message });
    return;
  }

  try {
    const { max_tokens, messages } = req.body || {};
    if (!Array.isArray(messages) || !messages.length) {
      res.status(400).json({ message: 'طلب غير صالح' });
      return;
    }

    const upstream = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-sonnet-5',
        // سقف ١٠٠٠ كان يقطع مخرجات الاختبارات؛ ونحدّ الأعلى لأن النقطة عامة
        max_tokens: Math.min(Number(max_tokens) || 4000, 8000),
        messages
      })
    });

    const data = await upstream.json();

    if (!upstream.ok) {
      res.status(upstream.status).json({
        message: (data && data.error && data.error.message) || 'تعذر الاتصال بخدمة الذكاء الاصطناعي'
      });
      return;
    }

    res.status(200).json(data);
  } catch (e) {
    console.error(e);
    res.status(502).json({ message: 'تعذر الاتصال بخدمة الذكاء الاصطناعي، حاول مرة أخرى.' });
  }
};
