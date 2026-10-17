-- 六爻卦館 會員／訂閱／卦師解卦  資料庫結構
-- 用法：Supabase 後台 → SQL Editor → 貼上整份 → Run（可重複執行）

-- ── 方案設定（改價錢、卦數改這裡）─────────────────────────
create table if not exists public.plans (
  id text primary key,            -- basic / plus / pro
  name text not null,
  price int not null,             -- 每月價格（台幣）
  readings int,                   -- 每月卦數；null = 不限
  daily_cap int,                  -- 不限方案的每日合理上限
  sort int default 0
);
insert into public.plans (id,name,price,readings,daily_cap,sort) values
  ('basic','入門',100,10,null,1),
  ('plus','進階',299,30,null,2),
  ('pro','無限',599,null,30,3)
on conflict (id) do nothing;

-- ── 會員 ───────────────────────────────────────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  plan text references public.plans(id),
  period_start timestamptz,
  period_end timestamptz,
  used int not null default 0,     -- 本期已用卦數
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = uid), false)
$$;

-- ── 轉帳回報 ────────────────────────────────────────────
create table if not exists public.payments (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan text not null references public.plans(id),
  amount int not null,
  method text not null check (method in ('line','bank')),
  ref text,                        -- 轉帳後五碼 / 備註
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);

-- ── 解卦紀錄（含追問）──────────────────────────────────
create table if not exists public.readings (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  question text,
  category text,
  chart text not null,
  answer text,
  thread jsonb not null default '[]'::jsonb,   -- 追問 [{q,a}]
  followups int not null default 0,
  model text
);
create index if not exists readings_user_time on public.readings(user_id, created_at desc);

-- ── 設定 ───────────────────────────────────────────────
create table if not exists public.public_settings (key text primary key, value text);   -- 所有人可讀（收款資訊）
create table if not exists public.private_settings (key text primary key, value text);  -- 只有伺服器讀（規則書、模型）
insert into public.public_settings values
  ('payment_info','【LINE 轉帳】請加官方 LINE 後轉帳\n【銀行轉帳】銀行代碼：___　帳號：___　戶名：___\n轉帳後在下方填寫「帳號後五碼」，我們確認後立即開通。'),
  ('followup_limit','3')
on conflict (key) do nothing;
insert into public.private_settings values
  ('model','claude-sonnet-5-5'),
  ('max_tokens','1500'),
  ('rules','你是一位六爻卦師，依火珠林法（納甲筮法）斷卦。（規則書訓練中，之後由管理頁更新）')
on conflict (key) do nothing;

-- ── 權限（RLS）──────────────────────────────────────────
alter table public.plans enable row level security;
alter table public.profiles enable row level security;
alter table public.payments enable row level security;
alter table public.readings enable row level security;
alter table public.public_settings enable row level security;
alter table public.private_settings enable row level security;

drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select using (true);

drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles for select using (id = auth.uid() or public.is_admin(auth.uid()));

drop policy if exists payments_self_read on public.payments;
create policy payments_self_read on public.payments for select using (user_id = auth.uid() or public.is_admin(auth.uid()));
drop policy if exists payments_self_insert on public.payments;
create policy payments_self_insert on public.payments for insert with check (user_id = auth.uid() and status = 'pending');

drop policy if exists readings_self on public.readings;
create policy readings_self on public.readings for select using (user_id = auth.uid() or public.is_admin(auth.uid()));

drop policy if exists public_settings_read on public.public_settings;
create policy public_settings_read on public.public_settings for select using (true);
-- private_settings 沒有任何 policy：只有伺服器（service role）讀得到

-- ── 函式 ───────────────────────────────────────────────
-- 扣一卦（伺服器呼叫）：回傳新紀錄 id，或丟出 expired / no_plan / quota / daily_cap
create or replace function public.consume_reading(uid uuid, q text, cat text, chart_text text, model_name text)
returns bigint language plpgsql security definer set search_path = public as $$
declare p public.profiles; pl public.plans; today_count int; rid bigint;
begin
  select * into p from public.profiles where id = uid for update;
  if p.plan is null then raise exception 'no_plan'; end if;
  if p.period_end is null or p.period_end < now() then raise exception 'expired'; end if;
  select * into pl from public.plans where id = p.plan;
  if pl.readings is not null and p.used >= pl.readings then raise exception 'quota'; end if;
  if pl.daily_cap is not null then
    select count(*) into today_count from public.readings
      where user_id = uid and created_at >= date_trunc('day', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
    if today_count >= pl.daily_cap then raise exception 'daily_cap'; end if;
  end if;
  update public.profiles set used = used + 1 where id = uid;
  insert into public.readings (user_id, question, category, chart, model) values (uid, q, cat, chart_text, model_name) returning id into rid;
  return rid;
end $$;
revoke all on function public.consume_reading(uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.consume_reading(uuid,text,text,text,text) to service_role;

-- 解卦失敗時退回一卦（伺服器呼叫）
create or replace function public.refund_reading(rid bigint) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  delete from public.readings where id = rid and answer is null returning user_id into u;
  if u is not null then update public.profiles set used = greatest(used - 1, 0) where id = u; end if;
end $$;
revoke all on function public.refund_reading(bigint) from public, anon, authenticated;
grant execute on function public.refund_reading(bigint) to service_role;

-- 管理員核准轉帳：方案從今天起算 30 天、次數歸零（用完升級就等於時間往後延）
create or replace function public.approve_payment(pid bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.payments;
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  select * into pay from public.payments where id = pid for update;
  if pay.status <> 'pending' then raise exception 'not_pending'; end if;
  update public.payments set status = 'approved', decided_at = now(), decided_by = auth.uid() where id = pid;
  update public.profiles set plan = pay.plan, period_start = now(), period_end = now() + interval '30 days', used = 0 where id = pay.user_id;
end $$;

create or replace function public.reject_payment(pid bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  update public.payments set status = 'rejected', decided_at = now(), decided_by = auth.uid() where id = pid and status = 'pending';
end $$;

-- 管理員手動設定會員（贈送、補償、延長）
create or replace function public.admin_set_member(uid uuid, new_plan text, days int, reset_used boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  update public.profiles set
    plan = new_plan,
    period_start = case when new_plan is null then null else now() end,
    period_end = case when new_plan is null then null else now() + make_interval(days => days) end,
    used = case when reset_used then 0 else used end
  where id = uid;
end $$;

-- 管理員改設定（收款資訊、規則書、模型…）
create or replace function public.admin_set_setting(k text, v text, is_private boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  if is_private then insert into public.private_settings values (k, v) on conflict (key) do update set value = excluded.value;
  else insert into public.public_settings values (k, v) on conflict (key) do update set value = excluded.value; end if;
end $$;

create or replace function public.admin_get_private() returns setof public.private_settings
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  return query select * from public.private_settings;
end $$;

-- 管理員改價錢／卦數
create or replace function public.admin_set_plan(pid text, p_price int, p_readings int, p_daily int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  update public.plans set price = p_price, readings = p_readings, daily_cap = p_daily where id = pid;
end $$;

-- 第一次設定：把自己設成管理員（把信箱換成你的，註冊登入一次後再執行）
-- update public.profiles set is_admin = true where email = 'kevin87265@gmail.com';

-- ══ 第二版新增：開通碼、雲端起卦紀錄 ══════════════════════

-- ── 開通碼（管理員產生 → LINE 傳給會員 → 會員輸入開通；一碼一用）──
create table if not exists public.activation_codes (
  code text primary key,
  plan text not null references public.plans(id),
  days int not null default 30,
  note text,
  created_at timestamptz not null default now(),
  created_by uuid,
  used_by uuid references public.profiles(id) on delete set null,
  used_at timestamptz
);
create table if not exists public.redeem_fails (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  at timestamptz not null default now()
);
alter table public.activation_codes enable row level security;
alter table public.redeem_fails enable row level security;
drop policy if exists codes_admin on public.activation_codes;
create policy codes_admin on public.activation_codes for select using (public.is_admin(auth.uid()));

create or replace function public.admin_create_code(p_plan text, p_days int, p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare c text; h text;
begin
  if not public.is_admin(auth.uid()) then raise exception 'not_admin'; end if;
  loop
    h := upper(replace(gen_random_uuid()::text, '-', ''));
    h := translate(h, '0', 'G');                      -- 避免 0 跟 O 看錯
    c := substr(h,1,4) || '-' || substr(h,5,4) || '-' || substr(h,9,4);
    exit when not exists (select 1 from public.activation_codes where code = c);
  end loop;
  insert into public.activation_codes (code, plan, days, note, created_by) values (c, p_plan, greatest(p_days,1), p_note, auth.uid());
  return c;
end $$;

create or replace function public.redeem_code(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); k public.activation_codes; norm text; fails int;
begin
  if uid is null then raise exception 'login'; end if;
  select count(*) into fails from public.redeem_fails where user_id = uid and at > now() - interval '1 hour';
  if fails >= 8 then return json_build_object('error','too_many'); end if;
  norm := upper(regexp_replace(coalesce(p_code,''), '[^0-9A-Za-z]', '', 'g'));
  norm := translate(norm, '0', 'G');
  if length(norm) = 12 then norm := substr(norm,1,4) || '-' || substr(norm,5,4) || '-' || substr(norm,9,4); end if;
  select * into k from public.activation_codes where code = norm and used_by is null for update;
  if not found then insert into public.redeem_fails (user_id) values (uid); return json_build_object('error','invalid'); end if;   -- 用 return 不用 raise，失敗紀錄才會留下來
  update public.activation_codes set used_by = uid, used_at = now() where code = norm;
  update public.profiles set plan = k.plan, period_start = now(), period_end = now() + make_interval(days => k.days), used = 0 where id = uid;
  return json_build_object('plan', k.plan, 'days', k.days);
end $$;
revoke all on function public.redeem_code(text) from public, anon;
grant execute on function public.redeem_code(text) to authenticated;

-- ── 雲端起卦紀錄（登入後每次排盤自動存，換手機也看得到）──
create table if not exists public.casts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  cast_at timestamptz not null,
  question text,
  category text,
  grp text,
  yongshen text,
  how text,
  nums jsonb,
  lines jsonb not null,
  ben text,
  bian text,
  created_at timestamptz not null default now(),
  unique (user_id, cast_at)
);
create index if not exists casts_user_time on public.casts(user_id, cast_at desc);
alter table public.casts enable row level security;
drop policy if exists casts_own_read on public.casts;
create policy casts_own_read on public.casts for select using (user_id = auth.uid() or public.is_admin(auth.uid()));
drop policy if exists casts_own_insert on public.casts;
create policy casts_own_insert on public.casts for insert with check (user_id = auth.uid());
drop policy if exists casts_own_delete on public.casts;
create policy casts_own_delete on public.casts for delete using (user_id = auth.uid());
