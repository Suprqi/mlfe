// نقطة نهاية وسيطة لتحليل الصور (تصنيف الشواهد، قراءة الشهادات).
// نفس مبدأ /api/chat: المفتاح خادمي فقط.

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

  try {
    const { prompt, mediaType, imageData, max_tokens } = req.body || {};
    if (!prompt || !mediaType || !imageData) {
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
        max_tokens: max_tokens || 1200,
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageData } },
            { type: 'text', text: prompt }
          ]
        }]
      })
    });

    const data = await upstream.json();

    if (!upstream.ok) {
      res.status(upstream.status).json({
        message: (data && data.error && data.error.message) || 'تعذر تحليل الصورة'
      });
      return;
    }

    res.status(200).json(data);
  } catch (e) {
    console.error(e);
    res.status(502).json({ message: 'تعذر تحليل الصورة، حاول مرة أخرى.' });
  }
};
