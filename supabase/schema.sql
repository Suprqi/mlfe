-- مَلَفّي — مخطط قاعدة البيانات (Supabase / Postgres)
-- شغّله مرة واحدة من: Supabase → SQL Editor → New query → Run

-- ═══════════════════════════════════════════════════════════
-- ١) حالة التطبيق: صف واحد لكل معلم يحمل بياناته كاملة
--    التطبيق أصلًا يحفظ كل شيء في كائن واحد، فنبقي البنية نفسها
--    لتكون المزامنة مباشرة بلا إعادة تصميم للبيانات.
-- ═══════════════════════════════════════════════════════════
create table if not exists public.app_state (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  state       jsonb not null default '{}'::jsonb,
  -- رقم النسخة يمنع أن يدهس جهازٌ قديم تعديلاتِ جهاز أحدث
  version     bigint not null default 1,
  device      text,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- ═══════════════════════════════════════════════════════════
-- ٢) الاشتراك: تُكتب من الخادم فقط بعد تأكيد الدفع،
--    والمتصفح يقرأ ولا يكتب — وإلا فتح أي مستخدم الاشتراك بنفسه.
-- ═══════════════════════════════════════════════════════════
create table if not exists public.subscriptions (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  status      text not null default 'free'
              check (status in ('free','active','expired','cancelled')),
  plan        text,
  expires_at  timestamptz,
  provider    text,
  provider_ref text,
  updated_at  timestamptz not null default now()
);

-- ═══════════════════════════════════════════════════════════
-- ٣) عزل البيانات: كل معلم لا يصل إلا لصفّه
-- ═══════════════════════════════════════════════════════════
alter table public.app_state     enable row level security;
alter table public.subscriptions enable row level security;

drop policy if exists app_state_select on public.app_state;
drop policy if exists app_state_insert on public.app_state;
drop policy if exists app_state_update on public.app_state;

create policy app_state_select on public.app_state
  for select using (auth.uid() = user_id);
create policy app_state_insert on public.app_state
  for insert with check (auth.uid() = user_id);
create policy app_state_update on public.app_state
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- الاشتراك للقراءة فقط من المتصفح؛ الكتابة عبر مفتاح الخدمة من الخادم
drop policy if exists subs_select on public.subscriptions;
create policy subs_select on public.subscriptions
  for select using (auth.uid() = user_id);

-- ═══════════════════════════════════════════════════════════
-- ٤) تحديث الطابع الزمني ورقم النسخة تلقائيًا عند كل حفظ
-- ═══════════════════════════════════════════════════════════
create or replace function public.touch_app_state()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.version    := coalesce(old.version, 0) + 1;
  return new;
end $$;

drop trigger if exists app_state_touch on public.app_state;
create trigger app_state_touch
  before update on public.app_state
  for each row execute function public.touch_app_state();

-- ═══════════════════════════════════════════════════════════
-- ٥) إنشاء صفوف المستخدم الجديد تلقائيًا عند التسجيل
-- ═══════════════════════════════════════════════════════════
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.app_state (user_id) values (new.id)
    on conflict (user_id) do nothing;
  insert into public.subscriptions (user_id) values (new.id)
    on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ═══════════════════════════════════════════════════════════
-- ٦) جائزة أفضل ملف إنجاز — التحكيم مُعمّى
--
--    جدولان لا جدول واحد، وهذا جوهر الأمر لا تنظيم:
--    · award_entrants يحمل هوية المعلّم (ضرورية للصرف).
--    · award_entries  يحمل الملف وإحصاءاته، ولا يحمل user_id إطلاقًا.
--
--    الربط بينهما بالرقم المرجعي وحده. فمن يطّلع على نسخة اللجنة لا
--    يملك طريقًا إلى صاحبها ما لم يملك مفتاح الخدمة. ولو وُضع العمودان
--    في جدول واحد لصار الإعماء وعدًا في واجهة لا قيدًا في البيانات.
-- ═══════════════════════════════════════════════════════════
create table if not exists public.award_entrants (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  ref        text unique not null,
  name       text,
  school     text,
  region     text,
  phone      text,
  email      text,
  updated_at timestamptz not null default now()
);

create table if not exists public.award_entries (
  ref          text primary key references public.award_entrants(ref) on delete cascade,
  html         text not null,
  replaced     integer not null default 0,   -- مواضع أسماء استُبدلت
  masked       integer not null default 0,   -- هوية أو جوال أو بريد طُمس
  image_count  integer not null default 0,
  suspects     jsonb   not null default '[]'::jsonb,
  stats        jsonb   not null default '{}'::jsonb,
  -- «مقبول» ليست الحالة الافتراضية: ما بقي فيه اسم أول أو نمط هوية
  -- يُعلَّق للمراجعة، فلا يصل إلى محكّم ملفٌ يحمل بيانات قاصر.
  status       text not null default 'received'
               check (status in ('received','needs_review','disqualified','judged')),
  app_version  text,
  submitted_at timestamptz not null default now()
);

-- لا سياسة على الجدولين. RLS مفعّل بلا policy يعني: لا يقرأ منهما
-- ولا يكتب فيهما أحدٌ بمفتاح المتصفح — لا صاحب الملف ولا غيره.
-- الوصول الوحيد عبر مفتاح الخدمة من /api/award-submit.
alter table public.award_entrants enable row level security;
alter table public.award_entries  enable row level security;

-- ما تراه لجنة التحكيم — ولا شيء غيره.
-- امنح المحكّمين هذا العرض لا الجدول، فهو لا يحمل عمودًا يقود لهوية.
create or replace view public.award_judging as
  select ref, html, stats, image_count, replaced, masked,
         status, submitted_at
    from public.award_entries;

-- حذف الحساب يمحو المشاركة كذلك: الهوية بالتتالي من auth.users،
-- ونسخة اللجنة بالتتالي من الهوية. لا يبقى أثر بعد الحذف.
