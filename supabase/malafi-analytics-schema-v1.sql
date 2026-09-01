-- ═══════════════════════════════════════════════════════════════
-- ملفّي · طبقة التحليلات — نسخة ١.٠
-- تُنشأ على قاعدة البيانات السعودية بعد الترحيل، لا قبله.
-- كل View هنا يقابل سطرًا في «قاموس المؤشرات» داخل لوحة المؤسس.
-- اللوحة لا تحسب شيئًا في المتصفح — تقرأ من هذه الـViews فقط.
-- ═══════════════════════════════════════════════════════════════

-- ── ١ · الجداول الأساسية ──────────────────────────────────────

create table events (
  id             bigserial primary key,
  user_id        uuid references auth.users(id) on delete cascade,
  name           text not null,
  feature        text,
  properties     jsonb not null default '{}',
  session_id     text,
  platform       text check (platform in ('mobile','web')),
  schema_version int not null default 1,
  created_at     timestamptz not null default now()
);
create index on events (name, created_at desc);
create index on events (user_id, created_at desc);
create index on events (feature, created_at desc) where feature is not null;

-- حصر الأحداث في القائمة المعتمدة: أي اسم خارجها يُرفض عند الإدخال
alter table events add constraint events_name_allowed check (name in (
  'user_signed_up','profile_completed','book_uploaded','prep_created','exam_created',
  'results_analyzed','treatment_plan_created','evidence_attached','document_completed',
  'document_exported','export_failed','subscription_started','subscription_renewed',
  'subscription_cancelled','ai_call','ai_output_edited','feedback_sent'
));

-- حسابات الفريق الداخلي: تُستثنى من كل مؤشر
create table internal_accounts (user_id uuid primary key, note text);

-- سجل التدقيق: لا يُعدَّل ولا يُحذف من التطبيق
create table audit_log (
  id bigserial primary key, actor_id uuid not null, actor_role text not null,
  action text not null, target text, created_at timestamptz default now()
);
revoke update, delete on audit_log from authenticated, anon;

-- مفاتيح الطرح التدريجي
create table feature_flags (
  key text primary key, rollout_pct int not null default 100 check (rollout_pct between 0 and 100),
  updated_at timestamptz default now(), updated_by uuid
);

-- القرارات وقياس نتائجها
create table decisions (
  id text primary key, title text not null, problem text,
  metric_key text not null,
  baseline numeric not null, target numeric not null,
  state text not null default 'جديد'
    check (state in ('جديد','قيد التحقيق','تم القرار','قيد التنفيذ','قياس النتيجة','مغلق')),
  owner_id uuid, flag_key text references feature_flags(key), rollout_pct int,
  opened_at timestamptz default now(), measure_after interval default '7 days',
  closed_at timestamptz, result text
);
create table decision_measurements (
  id bigserial primary key,
  decision_id text references decisions(id) on delete cascade,
  measured_at timestamptz default now(), value numeric not null, cohort text
);

-- قاعدة الإغلاق: لا يُغلق قرار بلا قياس واحد على الأقل بعد مدة الانتظار
create or replace function guard_decision_close() returns trigger as $$
begin
  if new.state = 'مغلق' and old.state <> 'مغلق' then
    if not exists (
      select 1 from decision_measurements m
      where m.decision_id = new.id
        and m.measured_at >= new.opened_at + new.measure_after
    ) then
      raise exception 'لا يُغلق القرار % قبل قياس نتيجته بعد مدة الانتظار', new.id;
    end if;
    new.closed_at := now();
  end if;
  return new;
end $$ language plpgsql;

create trigger trg_decision_close before update on decisions
for each row execute function guard_decision_close();


-- ── ٢ · الأساس المشترك ────────────────────────────────────────

-- كل المؤشرات تُبنى فوق هذا: أحداث نظيفة بلا حسابات داخلية وبلا يتامى
create or replace view ev as
select e.* from events e
where e.user_id is not null
  and not exists (select 1 from internal_accounts i where i.user_id = e.user_id);


-- ── ٣ · Views المؤشرات ────────────────────────────────────────

-- active_user · نسخة ١.٠ · نافذة ٢٨ يومًا
create materialized view mv_overview as
select
  count(distinct user_id) filter (where created_at > now() - interval '28 days')  as active_28d,
  count(distinct user_id) filter (where created_at > now() - interval '1 day')    as active_today,
  count(*) filter (where name='user_signed_up' and created_at > now() - interval '1 day') as new_today,
  count(*) filter (where name='subscription_started' and created_at > now() - interval '1 day') as subs_today,
  coalesce(sum((properties->>'amount')::numeric)
    filter (where name='subscription_started' and created_at > now() - interval '1 day'),0) as rev_today,
  coalesce(sum((properties->>'cost_halalas')::numeric)/100
    filter (where name='ai_call' and created_at > now() - interval '1 day'),0) as ai_cost_today
from ev;

-- returned · D1/D7/D30 من signup
create materialized view mv_retention as
with s as (select user_id, min(created_at) t0 from ev where name='user_signed_up' group by 1)
select
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=s.user_id
    and e.created_at between s.t0+interval '24 hours' and s.t0+interval '48 hours'))/nullif(count(*),0),1) as d1,
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=s.user_id
    and e.created_at between s.t0+interval '6 days' and s.t0+interval '8 days'))/nullif(count(*),0),1) as d7,
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=s.user_id
    and e.created_at between s.t0+interval '29 days' and s.t0+interval '31 days'))/nullif(count(*),0),1) as d30
from s where s.t0 < now() - interval '31 days';

-- mv_cohorts: الاحتفاظ مقسَّمًا بأسبوع التسجيل — اللوحة تقرأه ولم يكن معرَّفًا.
-- مبني على نمط mv_retention نفسه، مع تجميع بأسبوع t0.
create materialized view mv_cohorts as
with s as (
  select user_id, min(created_at) t0 from ev where name='user_signed_up' group by 1
), c as (
  select date_trunc('week', t0) as wk, user_id, t0 from s
  where t0 < now() - interval '31 days'
)
select
  to_char(wk,'YYYY-"W"IW')                                    as week,
  count(*)                                                    as size,
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=c.user_id
    and e.created_at between c.t0+interval '24 hours' and c.t0+interval '48 hours'))/nullif(count(*),0),1) as d1,
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=c.user_id
    and e.created_at between c.t0+interval '6 days'  and c.t0+interval '8 days'))/nullif(count(*),0),1)  as d7,
  round(100.0*count(*) filter (where exists (select 1 from ev e where e.user_id=c.user_id
    and e.created_at between c.t0+interval '29 days' and c.t0+interval '31 days'))/nullif(count(*),0),1) as d30
from c group by wk order by wk desc limit 12;

-- القِمع الكامل: كل مرحلة تُحسب داخل ٣٠ يومًا من التسجيل
create materialized view mv_funnel as
with s as (select user_id, min(created_at) t0 from ev where name='user_signed_up' group by 1),
reached as (
  select s.user_id,
    bool_or(e.name='profile_completed')       as profile,
    bool_or(e.name in ('prep_created','exam_created')) as first_create,
    bool_or(e.name='document_completed')      as first_doc,
    count(distinct e.feature) >= 2            as second_feature,
    bool_or(e.name='subscription_started')    as subscribed,
    bool_or(e.name='subscription_renewed')    as renewed
  from s left join ev e
    on e.user_id=s.user_id and e.created_at between s.t0 and s.t0+interval '30 days'
  group by s.user_id)
select count(*) as signup,
  count(*) filter (where profile)        as profile,
  count(*) filter (where first_create)   as first_create,
  count(*) filter (where first_doc)      as first_doc,
  count(*) filter (where second_feature) as second_feature,
  count(*) filter (where subscribed)     as subscribed,
  count(*) filter (where renewed)        as renewed
from reached;

-- mcu · أوزان السلسلة: كتاب ١ · تحضير ٢ · اختبار ٢ · تحليل ٢ · خطة ٢ · شاهد ٣
create materialized view mv_chain as
with a as (select distinct user_id from ev where created_at > now() - interval '28 days'),
r as (
  select
    count(distinct user_id) filter (where name='book_uploaded')           as book,
    count(distinct user_id) filter (where name='prep_created')            as prep,
    count(distinct user_id) filter (where name='exam_created')            as exam,
    count(distinct user_id) filter (where name='results_analyzed')        as analysis,
    count(distinct user_id) filter (where name='treatment_plan_created')  as plan,
    count(distinct user_id) filter (where name='evidence_attached')       as evidence
  from ev where created_at > now() - interval '28 days')
select r.*, (select count(*) from a) as base,
  round((1.0*book/nullif((select count(*) from a),0)*1
       + 1.0*prep    /nullif((select count(*) from a),0)*2
       + 1.0*exam    /nullif((select count(*) from a),0)*2
       + 1.0*analysis/nullif((select count(*) from a),0)*2
       + 1.0*plan    /nullif((select count(*) from a),0)*2
       + 1.0*evidence/nullif((select count(*) from a),0)*3)/12*100) as mcu
from r;

-- mcu حسب الشريحة: نفس الحساب مقسّمًا على platform / plan / subject / tenure
create materialized view mv_mcu_segments as
select 'الجهاز' as dim, platform as seg, round(avg(user_mcu)) as mcu
from user_mcu_rollup group by platform
union all select 'الاشتراك', plan, round(avg(user_mcu)) from user_mcu_rollup group by plan
union all select 'المادة',  subject, round(avg(user_mcu)) from user_mcu_rollup group by subject
union all select 'العمر في المنصة',
  case when tenure_days < 30 then 'جديد — أقل من ٣٠ يومًا' else 'قديم — أكثر من ٣٠ يومًا' end,
  round(avg(user_mcu)) from user_mcu_rollup group by 2;

-- feature_used · «استخدم» = أنتج مخرَجًا، لا مجرد فتح
create materialized view mv_features as
with a as (select count(distinct user_id) n from ev where created_at > now() - interval '28 days')
select feature,
  round(100.0*count(distinct user_id)/nullif((select n from a),0),1) as used_pct,
  round(100.0*count(distinct user_id) filter (where cnt >= 2)
        /nullif(count(distinct user_id),0),1)                        as repeat_pct,
  sum(cnt)                                                            as outputs
from (select feature, user_id, count(*) cnt from ev
      where created_at > now() - interval '28 days' and feature is not null
        and name in ('prep_created','exam_created','results_analyzed',
                     'treatment_plan_created','evidence_attached','document_completed')
      group by 1,2) t
group by feature;

-- ai_cost_per_output + edit_rate
create materialized view mv_ai as
select feature,
  round(sum((properties->>'cost_halalas')::numeric)/100,2)                       as cost_sar,
  count(*) filter (where name='ai_call')                                         as calls,
  round(avg((properties->>'ms')::numeric))                                       as avg_ms,
  round(100.0*count(*) filter (where name='ai_call' and (properties->>'ok')::bool is false)
        /nullif(count(*) filter (where name='ai_call'),0),1)                      as fail_pct,
  round(100.0*count(*) filter (where name='ai_output_edited')
        /nullif(count(*) filter (where name='ai_call'),0),1)                      as edit_pct
from ev where name in ('ai_call','ai_output_edited')
  and created_at >= date_trunc('month', now())
group by feature;

-- export_fail · نافذة ٧ أيام متحركة
create materialized view mv_ops as
select round(100.0*count(*) filter (where name='export_failed')
  /nullif(count(*) filter (where name in ('document_exported','export_failed')),0),2) as pdf_fail_pct,
  count(*) filter (where name='export_failed') as fails_7d
from ev where created_at > now() - interval '7 days';

-- churn · الإلغاء يُحتسب عند نهاية الفترة المدفوعة
create materialized view mv_economy as
select
  count(distinct user_id) filter (where name='subscription_started'
    and created_at >= date_trunc('month',now()))                                  as new_subs,
  count(distinct user_id) filter (where name='subscription_cancelled'
    and created_at >= date_trunc('month',now()))                                  as cancels,
  coalesce(sum((properties->>'amount')::numeric) filter (where name in
    ('subscription_started','subscription_renewed')
    and created_at >= date_trunc('month',now())),0)                               as mrr
from ev;

-- request_weight · عدد المطالبين × (١ + نسبة المشتركين منهم)
create materialized view mv_voice as
select properties->>'type' as kind, feature,
  count(distinct user_id) as requesters,
  count(distinct user_id) filter (where user_id in (select user_id from ev where name='subscription_started')) as paid,
  round(count(distinct user_id) * (1 +
    1.0*count(distinct user_id) filter (where user_id in (select user_id from ev where name='subscription_started'))
    /nullif(count(distinct user_id),0)),1) as weight
from ev where name='feedback_sent' and created_at > now() - interval '90 days'
group by 1,2 order by weight desc;

-- health · تُحسب ليليًا ٠٣:٠٠ · نشاط ٢٥ + عودة ٢٥ + إنتاج ٢٠ + ترابط ٢٠ + ملف الأداء ١٠
create materialized view mv_users as
select user_id,
  least(25, round(25.0*active_days_28/12))        as c_activity,
  least(25, round(25.0*return_weeks/4))           as c_return,
  least(20, round(20.0*docs_completed/10))        as c_output,
  least(20, round(20.0*distinct_chain_steps/6))   as c_connected,
  least(10, round(10.0*portfolio_completion))     as c_portfolio
from user_rollup
where first_seen < now() - interval '14 days';   -- الأحدث «قيد التكوّن» ولا تُعطى درجة


-- مصدر الاكتساب: يُثبَّت مرة واحدة لكل مستخدم، ولا يُحدَّث بعدها (أول لمسة تفوز)
create materialized view mv_acquisition as
with first_touch as (
  select distinct on (user_id) user_id,
    coalesce(properties->>'source','direct') as source,
    properties->>'referrer_id'               as referrer_id,
    created_at
  from ev where name='user_signed_up'
  order by user_id, created_at asc
),
outcome as (
  select f.source, f.user_id, f.created_at,
    exists(select 1 from ev e where e.user_id=f.user_id and e.name='document_completed') as activated,
    exists(select 1 from ev e where e.user_id=f.user_id and e.name='subscription_started') as paid,
    exists(select 1 from ev e where e.user_id=f.user_id and e.name='subscription_renewed') as renewed,
    exists(select 1 from ev e where e.user_id=f.user_id
           and e.created_at between f.created_at+interval '29 days' and f.created_at+interval '31 days') as kept_30d
  from first_touch f
)
select source,
  count(*)                                                            as signups,
  round(100.0*count(*) filter (where activated)/count(*),1)           as activated_pct,
  round(100.0*count(*) filter (where paid)     /count(*),1)           as paid_pct,
  round(100.0*count(*) filter (where kept_30d) /count(*),1)           as d30_pct,
  round(100.0*count(*) filter (where renewed)
        /nullif(count(*) filter (where paid),0),1)                    as renew_pct,
  round(
    (100.0*count(*) filter (where paid)/count(*)) *
    (100.0*count(*) filter (where renewed)/nullif(count(*) filter (where paid),0)) / 100, 1) as quality
from outcome
where created_at < now() - interval '30 days'   -- الأفواج الأحدث لم تنضج بعد
group by source
having count(*) >= 50                            -- أقل من ٥٠ تسجيلًا لا يُرتَّب
order by quality desc;

-- شجرة الإحالة: أي معلم يجلب معلمين، وكم يبقى منهم
create materialized view mv_referrals as
select properties->>'referrer_id' as referrer_id,
  count(*) as invited,
  count(*) filter (where exists (select 1 from ev e
    where e.user_id=ev.user_id and e.name='subscription_started')) as invited_paid
from ev where name='user_signed_up' and properties->>'referrer_id' is not null
group by 1 order by invited desc;

-- حارس: نسبة المجهول. فوق ١٥٪ يسقط جدول القنوات من الصلاحية للقرار
create or replace view vw_attribution_health as
select round(100.0*count(*) filter (where coalesce(properties->>'source','direct')='direct')
  /nullif(count(*),0),1) as unattributed_pct,
  count(*) as signups_90d
from ev where name='user_signed_up' and created_at > now() - interval '90 days';

-- ── ٤ · طبقة الثقة: الرقم الخاطئ أخطر من الرقم الغائب ─────────

create materialized view mv_data_quality as
with tot as (select count(*) n from events where created_at > now() - interval '24 hours'),
orphan as (select count(*) n from events where user_id is null and created_at > now() - interval '24 hours'),
missing_platform as (select count(*) n from events where platform is null and created_at > now() - interval '24 hours'),
lag_ai as (select extract(epoch from now()-max(created_at))/60 m from events where name='ai_call'),
freshness as (select extract(epoch from now()-max(created_at))/60 m from events)
select
  round(100.0*(1 - (select n from orphan)::numeric/nullif((select n from tot),0)
                 - (select n from missing_platform)::numeric/nullif((select n from tot),0)), 1) as score,
  (select n from tot)              as events_24h,
  (select n from orphan)           as orphan_events,
  (select n from missing_platform) as missing_platform,
  (select m from freshness)        as sync_lag_minutes,
  (select m from lag_ai)           as ai_sync_lag_minutes;

-- مطابقة مصدر خارجي مستقل: أخطر فحص وأهمه
-- عدد الاشتراكات المسجّلة عندنا يجب أن يطابق عمليات ميسر الناجحة
create or replace view vw_payment_reconciliation as
select d::date as day,
  (select count(*) from ev where name='subscription_started' and created_at::date=d::date) as internal,
  (select count(*) from moyasar_payments where status='paid' and created_at::date=d::date)  as external
from generate_series(now()-interval '30 days', now(), '1 day') d;
-- أي يوم يختلف فيه العمودان يُسقِط جودة البيانات ويُعلَّم المؤشر المالي في اللوحة


-- ── ٥ · التحديث ───────────────────────────────────────────────
-- pg_cron أو Edge Function:
--   كل ٥ دقائق : mv_overview, mv_ops, mv_data_quality
--   كل ساعة    : mv_features, mv_ai, mv_economy, mv_voice
--   ٠٣:٠٠ يوميًا: mv_users, mv_chain, mv_mcu_segments, mv_funnel, mv_retention,
--                mv_acquisition, mv_referrals
-- refresh materialized view concurrently mv_overview;
