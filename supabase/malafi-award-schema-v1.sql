
-- ═══════════════════════════════════════════════════════════════
-- ملفّي · طبقة الجائزة والتحكيم — نسخة ١.٠
-- الرابط بين التطبيق (awBuildPayload) ولوحة المؤسس (تبويب الجائزة).
-- تُنشأ بعد جداول التحليلات، على القاعدة السعودية.
--
-- مبدآن حاكمان:
--   ١. الاكتمال ≠ الجودة. الفحص الآلي يقيس الاكتمال فقط،
--      والجودة قرار لجنة بشرية.
--   ٢. النسخة المرسلة Snapshot ثابتة — لا تتبع تعديلات المعلم بعدها.
-- ═══════════════════════════════════════════════════════════════

-- ── ١ · دورة الجائزة ───────────────────────────────────────────
-- عتبات الأهلية بيانات إدارية لا ثوابت في الكود:
-- «قرار إداري حساس لا يُدفن داخل الخوارزمية».
create table award_cycles (
  id                 bigserial primary key,
  title              text not null,                 -- «جائزة أفضل ملف إنجاز ١٤٤٨هـ»
  hijri_year         text not null,
  opens_at           date not null,
  closes_at          date not null,
  eligible_min       int  not null default 100 check (eligible_min between 0 and 100),
  review_min         int  not null default 90  check (review_min  between 0 and 100),
  auto_exclude       bool not null default false,   -- استبعاد غير المكتمل تلقائيًا؟
  tie_break_rule     text,                          -- يُعلَن قبل الفتح لا بعد ظهور التعادل
  created_at         timestamptz default now(),
  constraint award_window   check (closes_at > opens_at),
  constraint award_thresholds check (eligible_min >= review_min)
);

-- ── ٢ · طلب المشاركة ──────────────────────────────────────────
create type award_status as enum
  ('draft','submitted','auto_checked','eligible','needs_review','ineligible','judging','judged','withdrawn');

create table award_submissions (
  id             bigserial primary key,
  ref            text unique not null,              -- M-0248 — ما يراه المحكّم
  cycle_id       bigint not null references award_cycles(id) on delete restrict,
  user_id        uuid   not null references auth.users(id)  on delete restrict,

  -- Snapshot: يُكتب مرة واحدة ولا يُحدَّث بعدها
  html           text not null,
  stats          jsonb not null default '{}',       -- {evidence, students, workPairs}
  replaced       int  not null default 0,           -- أسماء طلاب استُبدلت
  masked_ids     int  not null default 0,
  image_count    int  not null default 0,
  suspects       text[] not null default '{}',      -- أسماء أولى لم تُستبدل
  app_version    text,

  -- بيانات المشارك: للإدارة وصرف الجائزة فقط — لا يراها المحكّم
  teacher        jsonb not null default '{}',

  completeness   int,                               -- ٠–١٠٠ من الفحص الآلي
  gaps           jsonb not null default '[]',       -- [{standard, state, count}]
  status         award_status not null default 'submitted',
  status_note    text,
  submitted_at   timestamptz not null default now(),
  checked_at     timestamptz,
  updated_at     timestamptz default now()
);

-- ملف فعّال واحد لكل معلم في كل دورة: الإرسال الجديد يستبدل السابق
create unique index award_one_active
  on award_submissions (cycle_id, user_id)
  where status <> 'withdrawn';

create index on award_submissions (cycle_id, status);
create index on award_submissions (cycle_id, completeness desc);

-- Snapshot ثابت: أي محاولة لتعديل الحمولة بعد الإرسال تُرفض
create or replace function award_freeze() returns trigger as $$
begin
  if (new.html, new.stats, new.replaced, new.image_count) is distinct from
     (old.html, old.stats, old.replaced, old.image_count) then
    raise exception 'Snapshot مجمّد — لا تُعدَّل النسخة المرسلة بعد التسليم';
  end if;
  new.updated_at := now();
  return new;
end $$ language plpgsql;

create trigger award_freeze_trg before update on award_submissions
  for each row execute function award_freeze();

-- رفض ما يصل بعد الإقفال
create or replace function award_window_guard() returns trigger as $$
declare c award_cycles%rowtype;
begin
  select * into c from award_cycles where id = new.cycle_id;
  if current_date < c.opens_at then raise exception 'باب التسليم لم يُفتح بعد'; end if;
  if current_date > c.closes_at then raise exception 'أُقفل باب التسليم'; end if;
  return new;
end $$ language plpgsql;

create trigger award_window_trg before insert on award_submissions
  for each row execute function award_window_guard();

-- ── ٣ · بطاقة التحكيم ─────────────────────────────────────────
-- المعايير والأوزان تحددها الإدارة لكل دورة — ليست ثوابت.
create table award_criteria (
  id        bigserial primary key,
  cycle_id  bigint not null references award_cycles(id) on delete cascade,
  label     text not null,
  weight    int  not null check (weight between 1 and 100),
  sort      int  not null default 0
);

create table award_scores (
  id            bigserial primary key,
  submission_id bigint not null references award_submissions(id) on delete cascade,
  judge_id      uuid   not null references auth.users(id),
  criterion_id  bigint not null references award_criteria(id) on delete cascade,
  score         numeric(5,2) not null check (score >= 0),
  note          text,
  created_at    timestamptz default now(),
  unique (submission_id, judge_id, criterion_id)
);

-- كشف هوية صاحب الملف: مسجَّل دائمًا. الحياد يُثبَت بالأثر لا بالادّعاء.
create table award_reveals (
  id            bigserial primary key,
  submission_id bigint not null references award_submissions(id) on delete cascade,
  actor_id      uuid not null,
  reason        text not null,
  created_at    timestamptz default now()
);
revoke update, delete on award_reveals from authenticated, anon;

-- ── ٤ · ما يراه المحكّم — بلا اسم ولا مدرسة ولا جوال ──────────
create or replace view vw_judge_queue as
select s.id, s.ref, s.cycle_id, s.completeness, s.stats, s.image_count,
       s.replaced, cardinality(s.suspects) as suspects_count, s.status
from award_submissions s
where s.status in ('eligible','judging');
-- ملاحظة تنفيذ: teacher و html الخام لا يُمرَّران لواجهة المحكّم.
-- يُقرأ html من نقطة نهاية منفصلة تتحقق من دور المحكّم.

-- ── ٥ · نتيجة التحكيم والتعادل ────────────────────────────────
create materialized view mv_award_results as
-- وزن المعيار هو درجته القصوى، فدرجة المحكّم = مجموع درجاته،
-- والنتيجة النهائية متوسط المحكّمين لا متوسط موزون للمعايير.
with per_judge as (
  select submission_id, judge_id, sum(score) as judge_total
  from award_scores group by 1,2
), agg as (
  select submission_id,
         round(avg(judge_total), 2)      as final_score,
         count(distinct judge_id)        as judges
  from per_judge group by 1
)
select s.id, s.ref, s.cycle_id, s.completeness,
       a.final_score, a.judges,
       rank() over (partition by s.cycle_id order by a.final_score desc) as place,
       count(*) over (partition by s.cycle_id, a.final_score) > 1 as tied
from award_submissions s
join agg a on a.submission_id = s.id
where s.status = 'judged';

-- ── ٦ · لوحة الجائزة — الأرقام التي يقرؤها تبويب اللوحة ───────
create materialized view mv_award_overview as
select
  c.id as cycle_id, c.title, c.hijri_year, c.opens_at, c.closes_at,
  c.eligible_min, c.review_min, c.auto_exclude,
  count(s.id)                                              as received,
  count(*) filter (where s.status = 'eligible')            as eligible,
  count(*) filter (where s.status = 'needs_review')        as needs_review,
  count(*) filter (where s.status = 'ineligible')          as ineligible,
  count(*) filter (where s.status = 'judging')             as judging,
  count(*) filter (where s.status = 'judged')              as judged,
  count(*) filter (where cardinality(s.suspects) > 0)      as with_suspects,
  round(avg(s.completeness), 1)                            as avg_completeness
from award_cycles c
left join award_submissions s on s.cycle_id = c.id and s.status <> 'withdrawn'
group by c.id;

create materialized view mv_award_ties as
select cycle_id, final_score, count(*) as n,
       array_agg(ref order by ref) as refs
from mv_award_results
group by cycle_id, final_score
having count(*) > 1;


-- ── ٧ · الفحص الآلي — تطبيق العتبات ───────────────────────────
-- يقيس الاكتمال فقط. لا يقيّم جودة، ولا يرتّب فائزًا.
-- والقرار الإداري الحساس (استبعاد غير المكتمل) قراءةٌ من award_cycles
-- لا شرطٌ مدفون في الكود.
create or replace function award_autocheck(p_submission bigint)
returns award_status as $$
declare
  s award_submissions%rowtype;
  c award_cycles%rowtype;
  new_status award_status;
begin
  select * into s from award_submissions where id = p_submission;
  select * into c from award_cycles      where id = s.cycle_id;

  -- ١) أسماء أولى لم تُستبدل ⇒ مراجعة بشرية قبل أي شيء.
  --    ملف يصل للمحكّم باسم طالب يُسقط حياد الجائزة كلها.
  if cardinality(s.suspects) > 0 then
    new_status := 'needs_review';

  -- ٢) العتبات كما حددتها الإدارة لهذه الدورة
  elsif s.completeness >= c.eligible_min then
    new_status := 'eligible';
  elsif s.completeness >= c.review_min then
    new_status := 'needs_review';
  else
    -- ٣) غير المكتمل: يُستبعد أو يُرسل مع إظهار نسبته — خيار الإدارة
    new_status := case when c.auto_exclude then 'ineligible' else 'needs_review' end;
  end if;

  update award_submissions
     set status = new_status,
         checked_at = now(),
         status_note = format('اكتمال %s%% · عتبة الأهلية %s%% · عتبة المراجعة %s%%%s',
                              s.completeness, c.eligible_min, c.review_min,
                              case when cardinality(s.suspects) > 0
                                   then format(' · %s اسمًا مشتبهًا', cardinality(s.suspects))
                                   else '' end)
   where id = p_submission;

  return new_status;
end $$ language plpgsql;

-- يعمل تلقائيًا عند وصول الملف
create or replace function award_autocheck_trg() returns trigger as $$
begin
  perform award_autocheck(new.id);
  return null;
end $$ language plpgsql;

create trigger award_autocheck_after after insert on award_submissions
  for each row execute function award_autocheck_trg();

-- ── ٨ · قائمة الفرز للإدارة — بالمرجع، والاسم خلف كشف مسجَّل ──
create or replace view vw_award_admin as
select s.id, s.ref, s.cycle_id, s.status, s.completeness, s.status_note,
       s.stats, s.image_count, cardinality(s.suspects) as suspects_count,
       s.submitted_at,
       exists(select 1 from award_reveals r where r.submission_id = s.id) as revealed
from award_submissions s
where s.status <> 'withdrawn';
-- teacher غير مُدرج عمدًا. كشفه عبر award_reveal() وحدها.

create or replace function award_reveal(p_submission bigint, p_reason text)
returns jsonb as $$
declare t jsonb;
begin
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'سبب الكشف إلزامي';
  end if;
  insert into award_reveals(submission_id, actor_id, reason)
       values (p_submission, auth.uid(), p_reason);
  select teacher into t from award_submissions where id = p_submission;
  return t;
end $$ language plpgsql security definer;


-- ── ٩ · حسم التعادل واعتماد المراكز ───────────────────────────
-- rank() تكشف التعادل ولا تحسمه. الحسم قرار لجنة يُسجَّل باسم صاحبه.
alter table award_submissions
  add column final_place  int check (final_place between 1 and 5),
  add column place_note    text,
  add column placed_by     uuid,
  add column placed_at     timestamptz;

create unique index award_one_per_place
  on award_submissions (cycle_id, final_place)
  where final_place is not null;

create or replace function award_resolve(
  p_submission bigint, p_place int, p_note text
) returns void as $$
declare s award_submissions%rowtype; c award_cycles%rowtype;
begin
  select * into s from award_submissions where id = p_submission;
  if s.status <> 'judged' then
    raise exception 'لا يُعتمد مركز لملف لم يكتمل تحكيمه';
  end if;
  select * into c from award_cycles where id = s.cycle_id;
  if coalesce(trim(c.tie_break_rule),'') = '' then
    raise exception 'معيار الحسم غير معلَن في هذه الدورة — يُكتب في award_cycles.tie_break_rule قبل الاعتماد';
  end if;
  if p_note is null or length(trim(p_note)) < 5 then
    raise exception 'سبب الاعتماد إلزامي';
  end if;
  update award_submissions
     set final_place = p_place, place_note = trim(p_note),
         placed_by = auth.uid(), placed_at = now()
   where id = p_submission;
  insert into audit_log(actor_id, actor_role, action, target)
       values (auth.uid(), 'award', format('اعتماد المركز %s — %s', p_place, trim(p_note)), s.ref);
end $$ language plpgsql security definer;

-- ── ١٠ · التحكيم: ما يراه المحكّم وما يُدخله ──────────────────
create table award_judge_assignments (
  submission_id bigint not null references award_submissions(id) on delete cascade,
  judge_id      uuid   not null references auth.users(id),
  assigned_at   timestamptz default now(),
  primary key (submission_id, judge_id)
);

-- طابور المحكّم: ملفاته هو فقط، بالمرجع، بلا أي بيان شخصي
create or replace view vw_my_judging as
select s.id, s.ref, s.cycle_id, s.completeness, s.stats, s.image_count,
       cardinality(s.suspects) as suspects_count,
       (select count(*) from award_scores x
         where x.submission_id = s.id and x.judge_id = auth.uid()) as scored_criteria,
       (select count(*) from award_criteria c where c.cycle_id = s.cycle_id) as total_criteria
from award_submissions s
join award_judge_assignments a
  on a.submission_id = s.id and a.judge_id = auth.uid()
where s.status in ('eligible','judging');

-- الملف ينتقل إلى judging عند أول درجة، وإلى judged عند اكتمال كل المحكّمين
create or replace function award_score_progress() returns trigger as $$
declare need int; have int; judges int;
begin
  select count(*) into need   from award_criteria where cycle_id =
    (select cycle_id from award_submissions where id = new.submission_id);
  select count(*) into judges from award_judge_assignments where submission_id = new.submission_id;
  select count(*) into have   from award_scores where submission_id = new.submission_id;

  if have >= need * judges and judges > 0 then
    update award_submissions set status='judged' where id=new.submission_id;
  else
    update award_submissions set status='judging'
     where id=new.submission_id and status='eligible';
  end if;
  return null;
end $$ language plpgsql;

create trigger award_score_progress_trg after insert or update on award_scores
  for each row execute function award_score_progress();
