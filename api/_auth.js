// التحقق من جلسة المستخدم قبل السماح باستدعاء الذكاء الاصطناعي.
// القيمتان أدناه عامّتان بطبيعتهما (نفس ما يُنشر في المتصفح)،
// والحماية الفعلية من سياسات RLS ومن التحقق من التوكن هنا.
const SUPA_URL = process.env.SUPABASE_URL || 'https://athqvuwpqellyqoyhdwx.supabase.co';
const SUPA_ANON = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF0aHF2dXdwcWVsbHlxb3loZHd4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU5NTUwNDEsImV4cCI6MjEwMTUzMTA0MX0.0OalkU0rCoX1RHGJpbWC_k4tdatNF_e9QCvREmIs5eM';

async function requireUser(req) {
  const header = req.headers.authorization || req.headers.Authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) {
    return { ok: false, message: 'سجّل دخولك لاستخدام مزايا الذكاء الاصطناعي' };
  }
  try {
    const r = await fetch(SUPA_URL + '/auth/v1/user', {
      headers: { apikey: SUPA_ANON, Authorization: 'Bearer ' + token }
    });
    if (!r.ok) {
      return { ok: false, message: 'انتهت جلستك — سجّل الدخول من جديد' };
    }
    const user = await r.json();
    if (!user || !user.id) {
      return { ok: false, message: 'تعذّر التحقق من حسابك — سجّل الدخول من جديد' };
    }
    // التحقق من الاشتراك يبقى مطفأً حتى تُفعّل بوابة الدفع، وإلا حُجب
    // المعلمون عن مزايا يستخدمونها اليوم. فعّله بضبط ENFORCE_SUBSCRIPTION=1
    if (process.env.ENFORCE_SUBSCRIPTION === '1') {
      const allowed = await hasAccess(token, user);
      if (!allowed) {
        return { ok: false, message: 'انتهت فترتك التجريبية — اشترك لمواصلة مزايا الذكاء الاصطناعي' };
      }
    }
    return { ok: true, user };
  } catch (e) {
    // لا نمنع المعلم بسبب عطل مؤقت في التحقق، لكن نسجّله
    console.error('auth check failed', e);
    return { ok: false, message: 'تعذّر التحقق من حسابك، حاول بعد قليل' };
  }
}

// اشتراك فعّال أو فترة تجريبية سارية. تُقرأ من قاعدة البيانات لا من المتصفح.
const TRIAL_DAYS = 14;
async function hasAccess(token, user) {
  try {
    const r = await fetch(SUPA_URL + '/rest/v1/subscriptions?select=status,expires_at', {
      headers: { apikey: SUPA_ANON, Authorization: 'Bearer ' + token }
    });
    if (r.ok) {
      const rows = await r.json();
      const sub = rows && rows[0];
      if (sub && sub.status === 'active' && (!sub.expires_at || new Date(sub.expires_at) > new Date())) {
        return true;
      }
    }
  } catch (e) {
    // لا نحرم المعلم بسبب عطل في القراءة
    return true;
  }
  const created = user && user.created_at;
  if (!created) return false;
  const days = (Date.now() - new Date(created).getTime()) / 86400000;
  return days < TRIAL_DAYS;
}

module.exports = { requireUser, hasAccess };
