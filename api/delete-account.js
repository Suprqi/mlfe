// حذف الحساب نهائيًا: البيانات والاشتراك وحساب الدخول نفسه.
// نظام حماية البيانات الشخصية يعطي صاحب البيانات حقّ الحذف، ولا يكفي أن
// يمحو المعلّم جهازه ويبقى حسابه وبياناته عندنا.
//
// حذف المستخدم من نظام الدخول يحتاج مفتاح الخدمة، ولذلك تعيش هذه النقطة
// على الخادم: المفتاح لا يظهر في المتصفح إطلاقًا.
const { requireUser } = require('./_auth');

const SUPA_URL = process.env.SUPABASE_URL || 'https://athqvuwpqellyqoyhdwx.supabase.co';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function admin(path, method) {
  return fetch(SUPA_URL + path, {
    method,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: 'Bearer ' + SERVICE_KEY,
      'Content-Type': 'application/json',
      Prefer: 'return=minimal'
    }
  });
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ message: 'طريقة غير مسموحة' });
    return;
  }

  // المصادقة أولًا: لا يحذف أحدٌ حسابًا إلا حسابه هو، والمعرّف يأتي من
  // التوكن المُتحقَّق منه لا من جسم الطلب، وإلا حذف أيُّ مسجَّل حسابَ غيره.
  const gate = await requireUser(req);
  if (!gate.ok) {
    res.status(401).json({ message: gate.message });
    return;
  }

  if (!SERVICE_KEY) {
    console.error('delete-account: SUPABASE_SERVICE_ROLE_KEY غير مضبوط');
    res.status(500).json({ message: 'حذف الحساب غير مهيأ على الخادم' });
    return;
  }

  const uid = encodeURIComponent(gate.user.id);

  try {
    // البيانات ثم الاشتراك ثم الحساب. لو تعثّرت خطوة توقّفنا وأبلغنا،
    // فإبلاغه بحذفٍ لم يتمّ أسوأ من إخفاق صريح يعيد المحاولة بعده.
    const state = await admin('/rest/v1/app_state?user_id=eq.' + uid, 'DELETE');
    if (!state.ok) {
      console.error('delete-account: تعذّر حذف البيانات', await state.text());
      res.status(502).json({ message: 'تعذّر حذف بياناتك، حاول مرة أخرى' });
      return;
    }

    const sub = await admin('/rest/v1/subscriptions?user_id=eq.' + uid, 'DELETE');
    if (!sub.ok) {
      console.error('delete-account: تعذّر حذف الاشتراك', await sub.text());
      res.status(502).json({ message: 'تعذّر حذف اشتراكك، حاول مرة أخرى' });
      return;
    }

    const user = await admin('/auth/v1/admin/users/' + uid, 'DELETE');
    if (!user.ok) {
      console.error('delete-account: تعذّر حذف الحساب', await user.text());
      res.status(502).json({ message: 'حُذفت بياناتك، لكن تعذّر حذف الحساب — راسل tech@malaffi.sa' });
      return;
    }

    res.status(200).json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(502).json({ message: 'تعذّر إتمام الحذف، حاول مرة أخرى' });
  }
};
