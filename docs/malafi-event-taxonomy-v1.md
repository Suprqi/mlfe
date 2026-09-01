# ملفّي — عقد الأحداث (Event Taxonomy) · نسخة ١.٠

**الغرض:** كل رقم في لوحة المؤسس يجب أن يعود إلى حدث معرّف هنا. أي حدث غير مذكور في هذا الملف لا يُرسل، وأي رقم بلا حدث لا يُعرض.

**قبل التنفيذ:** تُنشأ جداول الأحداث على قاعدة البيانات السعودية بعد الترحيل، لا قبله.

---

## ١ · قواعد التسمية

| القاعدة | الصواب | الخطأ |
|---|---|---|
| كائن ثم فعل، ماضٍ، بحروف صغيرة | `document_exported` | `exportDoc` · `Export` |
| اسم ثابت لا يتغير بتغير الواجهة | `prep_created` | `prep_v2_created` |
| النسخة في الخاصية لا في الاسم | `prep_created {version:2}` | `prep_created_v2` |
| لا حدث بلا معنى تحليلي | — | `button_clicked` · `page_scrolled` |

**قاعدة الحظر:** ممنوع في `properties` أي اسم معلم أو طالب أو مدرسة، أي رقم هوية، أي محتوى وثيقة أو نص سؤال. المخالفة تعني تسريب بيانات شخصية إلى طبقة التحليلات.

---

## ٢ · الخصائص الإلزامية في كل حدث

| الحقل | النوع | ملاحظة |
|---|---|---|
| `user_id` | uuid | فارغ فقط قبل تسجيل الدخول — يُعزل ولا يُحذف |
| `name` | text | من القائمة أدناه حصرًا |
| `created_at` | timestamptz | وقت الخادم لا وقت الجهاز |
| `session_id` | text | يُولَّد عند فتح التطبيق |
| `platform` | text | `mobile` أو `web` — بدونه لا يمكن تفسير أي فجوة |
| `feature` | text | مفتاح الميزة كما في `feature_flags` |
| `properties` | jsonb | خصائص الحدث المحددة أدناه |
| `schema_version` | int | يرتفع عند تغيير خصائص الحدث |

---

## ٣ · الأحداث المعتمدة (١٧)

### المسار الأساسي

| الحدث | متى يُرسل بالضبط | خصائص إلزامية |
|---|---|---|
| `user_signed_up` | بعد إنشاء الحساب ونجاح التحقق | `source`, `source_detail`, `referrer_id` |
| `profile_completed` | عند حفظ آخر حقل إلزامي في الملف الشخصي | `fields_count`, `seconds_spent` |
| `book_uploaded` | بعد اكتمال استخراج النص لا عند بدء الرفع | `pages`, `method` (`ocr`/`paste`), `ms` |
| `prep_created` | عند حفظ التحضير لا عند فتح الشاشة | `source_book` (bool), `subject` |
| `exam_created` | عند حفظ الاختبار | `questions_count`, `from_bank` (bool) |
| `results_analyzed` | عند اكتمال التحليل وظهور النتيجة | `students_count`, `source` |
| `treatment_plan_created` | عند حفظ الخطة العلاجية | `from_analysis` (bool) |
| `evidence_attached` | عند ربط شاهد بعنصر تقييم | `element_id`, `source_feature` |
| `document_completed` | عند بلوغ الوثيقة حالة نهائية قابلة للتصدير | `doc_type`, `elements_count` |
| `document_exported` | عند نجاح التصدير فعليًا | `doc_type`, `format`, `pages`, `ms` |
| `export_failed` | عند فشل التصدير | `doc_type`, `pages`, `reason` |

---

## ٣أ · مصدر الاكتساب — الحقل الوحيد الذي لا يُسترجَع بأثر رجعي

كل حقل آخر في هذا الملف يمكن استدراكه لاحقًا. **مصدر الاكتساب لا يمكن.** إن سجّل ألف معلم قبل أن تلتقطه، فقدتَ إلى الأبد معرفة أي قناة جلبت المعلم الذي يجدد.

### القيم المعتمدة لـ `source`

| القيمة | متى | `source_detail` |
|---|---|---|
| `teacher_referral` | دخل عبر رابط دعوة من معلم | معرّف المعلم الداعي في `referrer_id` |
| `twitter` | وسم `?src=twitter` في الرابط | اسم الحملة أو المنشور |
| `whatsapp_group` | وسم `?src=wa` | اسم المجموعة إن وُجد |
| `search` | `document.referrer` من محرك بحث | المحرك |
| `event` | رمز يُوزَّع في فعالية أو تدريب | رمز الفعالية |
| `direct` | لا وسم ولا مُحيل | — |

### قواعد الالتقاط

1. **يُلتقط عند أول زيارة، لا عند التسجيل.** خزّن الوسم في `sessionStorage` لحظة وصول الزائر، واقرأه عند `user_signed_up`. المعلم قد يزور اليوم ويسجّل بعد أسبوع.
2. **أول لمسة تفوز.** لا تُحدَّث القيمة بعد إنشاء الحساب مهما تكررت زيارته من قنوات أخرى — وإلا صار كل مستخدم منسوبًا لآخر قناة رآها لا لمن جلبه.
3. **لا توزيع تقديري.** ما لا يُعرف مصدره يبقى `direct`. لا يُقسَّم على القنوات بالنِّسَب.
4. **إن تجاوز `direct` نسبة ١٥٪** فالجدول كله غير صالح للقرار، ويجب إصلاح الالتقاط قبل قراءته.

```js
// عند تحميل أي صفحة — قبل التسجيل بوقت طويل
(function captureSource(){
  if (sessionStorage.getItem('acq')) return;            // أول لمسة تفوز
  const p = new URLSearchParams(location.search);
  const src = p.get('src') || p.get('utm_source');
  const acq = src ? { source: src, detail: p.get('utm_campaign') || null,
                      referrer_id: p.get('ref') || null }
    : /google|bing|yandex/.test(document.referrer) ? { source:'search', detail:'google' }
    : { source:'direct', detail:null };
  sessionStorage.setItem('acq', JSON.stringify(acq));
})();

// عند التسجيل
const acq = JSON.parse(sessionStorage.getItem('acq') || '{"source":"direct"}');
track(EV.SIGNUP, { source: acq.source, source_detail: acq.detail, referrer_id: acq.referrer_id });
```

**رابط الإحالة:** `malafi.sa/?src=teacher_referral&ref=<معرّف_المعلم>` — يُولَّد لكل معلم من داخل التطبيق. الإحالة اليوم أكبر قناة، وهي الوحيدة التي تنمو من تلقاء نفسها إن قِيست.

### الاشتراك

| الحدث | متى | خصائص |
|---|---|---|
| `subscription_started` | عند تأكيد ميسر لا عند فتح صفحة الدفع | `plan`, `amount`, `trial` (bool) |
| `subscription_renewed` | عند نجاح التحصيل الدوري | `plan`, `months_active` |
| `subscription_cancelled` | عند نهاية الفترة المدفوعة لا عند طلب الإلغاء | `reason`, `months_active` |

### الذكاء الاصطناعي والصوت

| الحدث | متى | خصائص |
|---|---|---|
| `ai_call` | بعد رجوع النتيجة (نجاحًا أو فشلًا) | `feature`, `ms`, `tokens_in`, `tokens_out`, `cost_halalas`, `ok` (bool) |
| `ai_output_edited` | عند أول تعديل يدوي على مخرَج مولَّد | `feature`, `edit_ratio` |
| `feedback_sent` | عند إرسال اقتراح أو شكوى | `type`, `feature` |

---

## ٤ · التنفيذ

```js
export const EV = {
  SIGNUP:'user_signed_up', PROFILE:'profile_completed', BOOK:'book_uploaded',
  PREP:'prep_created', EXAM:'exam_created', ANALYSIS:'results_analyzed',
  PLAN:'treatment_plan_created', EVIDENCE:'evidence_attached',
  DOC_DONE:'document_completed', DOC_EXPORT:'document_exported', DOC_FAIL:'export_failed',
  SUB_START:'subscription_started', SUB_RENEW:'subscription_renewed', SUB_CANCEL:'subscription_cancelled',
  AI_CALL:'ai_call', AI_EDIT:'ai_output_edited', FEEDBACK:'feedback_sent'
};

const SESSION_ID = crypto.randomUUID();

export async function track(name, properties = {}, feature = null) {
  if (!Object.values(EV).includes(name)) {
    console.warn('حدث غير معتمد:', name);   // في التطوير فقط
    return;
  }
  try {
    await supabase.from('events').insert({
      user_id: (await supabase.auth.getUser()).data.user?.id ?? null,
      name, feature, properties,
      session_id: SESSION_ID,
      platform: window.matchMedia('(max-width:820px)').matches ? 'mobile' : 'web',
      schema_version: 1
    });
  } catch (_) {}   // التتبع لا يوقف المستخدم أبدًا
}
```

**قواعد التنفيذ:**

1. **الحدث يُرسل عند اكتمال الفعل، لا عند نيته.** `document_exported` بعد نجاح التصدير فعلًا، وإلا صار المؤشر كذبًا مهذبًا.
2. **لا تُرسل الأحداث من داخل حلقة أو `useEffect` بلا شرط.** كل تكرار زائد يفسد كل نسبة مبنية على مستخدمين فريدين.
3. **الفشل صامت للمستخدم ومسجَّل للنظام.** خطأ في التتبع لا يظهر للمعلم أبدًا.
4. **قبل كل إصدار:** شغّل قائمة الفحص في القسم ٦.

---

## ٥ · ترتيب التنفيذ

| المرحلة | الأحداث | ما تُفعّله في اللوحة |
|---|---|---|
| ١ — يوم واحد | `user_signed_up` **مع `source`**, `profile_completed`, `document_completed` | القِمع الأول، إكمال أول وثيقة، النشاط، مصدر الاكتساب |
| ٢ — يومان | مسار السلسلة الستة | MCU، تبنّي الميزات، خريطة الترابط |
| ٣ — يوم | `ai_call`, `ai_output_edited`, `export_failed` | تكلفة AI، جودة التوليد، صحة النظام |
| ٤ — يوم | أحداث الاشتراك | الإيراد، التحويل، التسرّب |
| ٥ — نصف يوم | `feedback_sent` | صوت المستخدم بالوزن |

المرحلة ١ وحدها تجعل نصف اللوحة حقيقيًا. لا داعي لانتظار الخمس مراحل.

---

## ٦ · فحص قبل الإطلاق

- [ ] كل حدث يظهر مرة واحدة فقط لكل فعل — تحقّق بجلسة يدوية وعدّ الصفوف.
- [ ] `platform` ممتلئ في ١٠٠٪ من الأحداث.
- [ ] لا حدث يحمل اسم معلم أو طالب أو مدرسة في `properties`.
- [ ] عدد `subscription_started` يطابق عدد عمليات ميسر الناجحة لليوم نفسه.
- [ ] مجموع `cost_halalas` يطابق فاتورة مزوّد النموذج بفارق أقل من ٢٪.
- [ ] `export_failed` + `document_exported` = مجموع محاولات التصدير.
- [ ] حسابات الفريق الداخلي مستثناة من كل المؤشرات.
- [ ] `source` ممتلئ في ٨٥٪ من التسجيلات على الأقل — وإلا فجدول القنوات لا يُقرأ.
- [ ] رابط إحالة واحد جُرِّب من طرف لطرف: زيارة ← انتظار ← تسجيل ← ظهور `referrer_id` صحيحًا.

> **ملاحظة توصيل:** الفحصان الرابع والخامس يعتمدان على `vw_payment_reconciliation` و`vw_attribution_health` في SQL — وهما **غير مقروءين في لوحة المؤسس** حتى الآن. أضِف اسميهما إلى `const VIEWS` في اللوحة، وإلا بقيت طبقة الثقة موجودة في قاعدة البيانات وغائبة عن عين المؤسس.

الفحص الرابع والخامس هما جوهر طبقة الثقة: عندما يتطابق الرقم الداخلي مع مصدر خارجي مستقل، تصبح اللوحة جديرة بقرار.
