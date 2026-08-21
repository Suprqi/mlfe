// استقبال ملف الإنجاز للمشاركة في الجائزة.
//
// المبدأ الحاكم: التحكيم مُعمّى. بيانات المعلّم ضرورية لصرف الجائزة فتصل
// إلى الخادم، لكنها تُخزَّن في جدول منفصل لا يصله محكّم. جدول نسخة اللجنة
// لا يحمل معرّف المستخدم أصلًا — يرتبط بالرقم المرجعي وحده — فلا يمكن
// الوصول من الملف إلى صاحبه إلا بمن يملك مفتاح الخدمة.
//
// وبابُ المشاركة مغلق افتراضيًا: يحتاج AWARD_OPEN=1 وتاريخ إقفال صريحًا.
// الافتراض الآمن هو الإغلاق، فاستقبال ملفات قبل إعلان الجائزة أسوأ من
// ردّها.
const { requireUser } = require('./_auth');

const SUPA_URL = process.env.SUPABASE_URL || 'https://athqvuwpqellyqoyhdwx.supabase.co';
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

// أكبر من حدّ العميل قليلًا: العميل يقيس الحمولة قبل الترميز، ولا نريد
// ردّ ملف مقبول بسبب فرق بايتات.
const MAX_BYTES = 4.4 * 1024 * 1024;

function db(path, method, body, extraPrefer) {
  return fetch(SUPA_URL + '/rest/v1' + path, {
    method,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: 'Bearer ' + SERVICE_KEY,
      'Content-Type': 'application/json',
      Prefer: extraPrefer || 'return=representation'
    },
    body: body ? JSON.stringify(body) : undefined
  });
}

// رقم مرجعي مقروء يذكره المعلّم في مراسلاته. بلا حروف تلتبس بالأرقام.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function makeRef() {
  let s = '';
  for (let i = 0; i < 6; i++) s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  return 'MLF-' + String(new Date().getFullYear()).slice(2) + '-' + s;
}

// فحص خادمي مستقل لا يثق بما أعلنه العميل. لا يمكننا إعادة مطابقة أسماء
// الطلاب هنا (الخادم لا يعرفها، وهذا مقصود)، لكن أنماط الهوية والجوال
// والبريد يمكن كشفها — ووجودها يعني أن التجريد لم يكتمل.
const LEAKS = [
  /[12][0-9]{9}/,
  /(?:\+?966|0)5[0-9]{8}/,
  /[\w.\-]+@[\w.\-]+\.\w{2,}/
];
function hasLeak(html) {
  return LEAKS.some(function (re) { return re.test(html); });
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ message: 'طريقة غير مسموحة' });
    return;
  }

  const gate = await requireUser(req);
  if (!gate.ok) {
    res.status(401).json({ message: gate.message });
    return;
  }

  if (!SERVICE_KEY) {
    console.error('award-submit: SUPABASE_SERVICE_ROLE_KEY غير مضبوط');
    res.status(500).json({ message: 'استقبال المشاركات غير مهيأ على الخادم' });
    return;
  }

  // ── باب المشاركة ──
  const closesAt = process.env.AWARD_CLOSES_AT;
  if (process.env.AWARD_OPEN !== '1' || !closesAt) {
    res.status(403).json({ message: 'باب المشاركة في الجائزة لم يُفتح بعد — تابع الإعلان في صفحة الجوائز' });
    return;
  }
  const deadline = new Date(closesAt);
  if (isNaN(deadline.getTime())) {
    console.error('award-submit: AWARD_CLOSES_AT غير صالح:', closesAt);
    res.status(500).json({ message: 'استقبال المشاركات غير مهيأ على الخادم' });
    return;
  }
  if (Date.now() > deadline.getTime()) {
    res.status(403).json({ message: 'أُقفل باب المشاركة في ' + deadline.toISOString().slice(0, 10) });
    return;
  }

  // ── الحمولة ──
  const len = parseInt(req.headers['content-length'] || '0', 10);
  if (len && len > MAX_BYTES) {
    res.status(413).json({ message: 'حجم الملف أكبر من الحدّ المسموح — قلّل صور الشواهد ثم أعد المحاولة' });
    return;
  }

  const p = req.body || {};
  if (typeof p.html !== 'string' || p.html.trim().length < 500) {
    res.status(400).json({ message: 'الملف المُرسل ناقص — ولّد ملف الإنجاز ثم أعد الإرسال' });
    return;
  }
  const stats = p.stats || {};
  if (!(stats.evidence >= 5) || !(stats.students >= 1) || !(stats.workPairs >= 1)) {
    res.status(400).json({ message: 'الملف لا يستوفي متطلبات المشاركة' });
    return;
  }

  // ── الحالة: «مقبول» ليست الافتراضية ──
  // أسماء أولى لم تُستبدل، أو نمط هوية/جوال/بريد بقي في النص، يعني أن
  // النسخة قد تحمل بيانات قاصر. تُعلَّق للمراجعة لا تُقبل.
  const suspects = Array.isArray(p.suspects) ? p.suspects.filter(function (s) { return typeof s === 'string'; }) : [];
  const leaked = hasLeak(p.html);
  const status = (suspects.length || leaked) ? 'needs_review' : 'received';

  const uid = gate.user.id;

  try {
    // ملف واحد فعّال لكل معلّم: نعيد استخدام رقمه المرجعي إن سبق أن شارك،
    // فلا يتغيّر الرقم الذي يعرفه ويُراسل به عند كل تحديث.
    const found = await fetch(
      SUPA_URL + '/rest/v1/award_entrants?select=ref&user_id=eq.' + encodeURIComponent(uid),
      { headers: { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY } }
    );
    if (!found.ok) {
      console.error('award-submit: تعذّرت قراءة المشارك', await found.text());
      res.status(502).json({ message: 'تعذّر الإرسال، حاول مرة أخرى' });
      return;
    }
    const rows = await found.json();
    const ref = (rows && rows[0] && rows[0].ref) || makeRef();

    // الهوية أولًا: نسخة اللجنة ترتبط بالرقم المرجعي، فلا بد أن يوجد.
    const ent = await db('/award_entrants', 'POST', {
      user_id: uid,
      ref: ref,
      name: String((p.teacher || {}).name || '').slice(0, 200),
      school: String((p.teacher || {}).school || '').slice(0, 200),
      region: String((p.teacher || {}).region || '').slice(0, 200),
      phone: String((p.teacher || {}).phone || '').slice(0, 40),
      email: String((p.teacher || {}).email || gate.user.email || '').slice(0, 200),
      updated_at: new Date().toISOString()
    }, 'resolution=merge-duplicates,return=minimal');
    if (!ent.ok) {
      console.error('award-submit: تعذّر حفظ بيانات المشارك', await ent.text());
      res.status(502).json({ message: 'تعذّر الإرسال، حاول مرة أخرى' });
      return;
    }

    // ثم نسخة اللجنة. لا تحمل user_id — الربط بالرقم المرجعي وحده.
    const entry = await db('/award_entries', 'POST', {
      ref: ref,
      html: p.html,
      replaced: parseInt(p.replaced, 10) || 0,
      masked: parseInt(p.masked, 10) || 0,
      image_count: parseInt(p.imageCount, 10) || 0,
      suspects: suspects,
      stats: stats,
      status: status,
      app_version: String(p.appVersion || '').slice(0, 20),
      submitted_at: new Date().toISOString()
    }, 'resolution=merge-duplicates,return=minimal');
    if (!entry.ok) {
      console.error('award-submit: تعذّر حفظ الملف', await entry.text());
      res.status(502).json({ message: 'تعذّر الإرسال، حاول مرة أخرى' });
      return;
    }

    res.status(200).json({ ok: true, ref: ref, status: status });
  } catch (e) {
    console.error('award-submit', e);
    res.status(502).json({ message: 'تعذّر الإرسال، حاول مرة أخرى' });
  }
};
