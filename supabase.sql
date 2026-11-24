-- =====================================================================
-- 매일툭챌린지 · Supabase 설정 v2 (기능 명세 2기)
-- 이 파일 전체를 SQL Editor에 붙여넣고 Run. 여러 번 실행해도 됩니다.
-- 주의: 이전 버전(v1)의 테이블과 테스트 등록 기록은 지워집니다.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- 0) v1 정리 ------------------------------------------------------------
drop view if exists public.board;
drop function if exists public.get_info();
drop function if exists public.join_challenge(text, int);
drop function if exists public.whoami(text);
drop function if exists public.relink_by_name(text);
drop function if exists public.check_in(text, text);
drop function if exists public.is_admin(text);
drop function if exists public.admin_set_day(text, uuid, date, text);
drop function if exists public.admin_remove_checkin(text, bigint);
drop function if exists public.admin_set_goal(text, uuid, int);
drop function if exists public.admin_remove(text, uuid);
drop function if exists public.admin_get_token(text, uuid);
drop function if exists public.admin_set_start(text, date);
drop function if exists public._setting(text);
drop function if exists public._admin_ok(text);
drop function if exists public._require_admin(text);
drop table if exists public.checkins;
drop table if exists public.settings;
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'participants' and column_name = 'token') then
    drop table public.participants cascade;
  end if;
end $$;

-- 1) 기본 도우미 --------------------------------------------------------
create or replace function public._norm(t text) returns text
language sql immutable as $$
  select lower(regexp_replace(coalesce(t, ''), '\s', '', 'g'))
$$;

create or replace function public._today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- w주차 인증 마감: 그 주가 끝난 다음 일요일 낮 12시(한국 시간)
create or replace function public._deadline(p_start date, p_week int) returns timestamptz
language sql immutable as $$
  select ((p_start + p_week * 7)::timestamp + interval '12 hours') at time zone 'Asia/Seoul'
$$;

create or replace function public._level(n int) returns int
language sql immutable as $$
  select case when n >= 120 then 5 when n >= 60 then 4 when n >= 20 then 3
              when n >= 10 then 2 when n >= 1 then 1 else 0 end
$$;

create or replace function public._types() returns text[]
language sql immutable as $$
  select array['instagram_reels','instagram_post','threads','youtube_long','youtube_shorts',
               'newsletter','blog','brunch','other']
$$;

-- URL 정규화: 호스트 소문자, www./m. 제거, #이하 제거, 추적용 파라미터 제거, 끝의 / 제거
create or replace function public._norm_url(u text) returns text
language plpgsql immutable as $$
declare v text := btrim(coalesce(u, '')); base text; q text; m text[]; host text; path text; kept text;
begin
  v := regexp_replace(v, '#.*$', '');
  base := split_part(v, '?', 1);
  q := substring(v from '\?(.*)$');
  m := regexp_match(base, '^https?://([^/\s]+)(/\S*)?$', 'i');
  if m is null then return null; end if;
  host := regexp_replace(lower(m[1]), '^(www|m)\.', '');
  if host !~ '\.' then return null; end if;
  path := regexp_replace(coalesce(m[2], ''), '/+$', '');
  if q is not null then
    select string_agg(p, '&' order by p) into kept
    from unnest(string_to_array(q, '&')) p
    where p <> '' and split_part(p, '=', 1) !~*
      '^(utm_.*|igsh|igshid|fbclid|gclid|si|feature|share|ref|source|trackingcode|hl|img_index|xmt|slof|app)$';
  end if;
  return 'https://' || host || path || coalesce('?' || kept, '');
end $$;

create or replace function public._classify(u text) returns text
language sql immutable as $$
  select case
    when u ~ '^https://instagram\.com/(.*/)?reels?/'                          then 'instagram_reels'
    when u ~ '^https://instagram\.com/(.*/)?p/'                               then 'instagram_post'
    when u ~ '^https://threads\.(net|com)(/|$)'                               then 'threads'
    when u ~ '^https://youtube\.com/shorts/'                                  then 'youtube_shorts'
    when u ~ '^https://(youtube\.com/(watch|live)|youtu\.be/)'                then 'youtube_long'
    when u ~ '^https://([^/]*\.)?brunch\.co\.kr(/|$)'                         then 'brunch'
    when u ~ '^https://([^/]*\.)?(blog\.naver\.com|tistory\.com|velog\.io|medium\.com)(/|$)' then 'blog'
    when u ~ '^https://([^/]*\.)?(stibee\.com|maily\.so|substack\.com)(/|$)'  then 'newsletter'
    else 'other' end
$$;

-- 2) 테이블 -------------------------------------------------------------
create table if not exists public.participants (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  pin_hash     text,                       -- null = 초기화됨(다음 로그인 때 새로 정함)
  is_admin     boolean not null default false,
  failed_count int not null default 0,
  locked_until timestamptz,
  level_seen   int not null default 0,
  created_at   timestamptz not null default now()
);
alter table public.participants add column if not exists avatar text;      -- 캐릭터 '도형-색' (예: 3-5)
alter table public.participants add column if not exists account_intro  text;   -- 계정 한 줄 소개(선택)
alter table public.participants add column if not exists account_target text;   -- 타겟(선택)
alter table public.participants add column if not exists account_value  text;   -- 제공 가치(선택)
alter table public.participants add column if not exists ig_username    text;   -- 성과 수집용 인스타그램 아이디(선택)
alter table public.participants add column if not exists account_story  jsonb;  -- 나의 이야기(계기·요즘·바꾼 것·자주 받는 질문). 본인에게만 보임
create unique index if not exists participants_name_norm_key on public.participants (public._norm(name));

create table if not exists public.seasons (
  id             int generated always as identity primary key,
  number         int not null unique,
  starts_on      date not null,
  ends_on        date not null,
  weekly_deposit int not null default 30000
);

create table if not exists public.enrollments (
  id               bigint generated always as identity primary key,
  participant_id   uuid not null references public.participants(id) on delete cascade,
  season_id        int  not null references public.seasons(id) on delete cascade,
  goal_types       text[] not null,
  weekly_goal      int not null check (weekly_goal between 1 and 5),
  main_channel_url text,
  created_at       timestamptz not null default now(),
  unique (participant_id, season_id)
);

create table if not exists public.posts (
  id                   bigint generated always as identity primary key,
  participant_id       uuid not null references public.participants(id) on delete cascade,
  enrollment_id        bigint not null references public.enrollments(id) on delete cascade,
  url                  text not null,
  url_normalized       text not null unique,
  content_type         text not null,
  published_on         date not null,
  week_no              int not null,
  counts_for_challenge boolean not null,
  created_at           timestamptz not null default now()
);
create index if not exists posts_enrollment_idx on public.posts (enrollment_id, week_no);

create table if not exists public.cheers (
  post_id        bigint not null references public.posts(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (post_id, participant_id)
);

create table if not exists public.sessions (
  token          text primary key,
  participant_id uuid not null references public.participants(id) on delete cascade,
  expires_at     timestamptz not null
);

create table if not exists public.weekly_settlements (
  season_id         int not null references public.seasons(id) on delete cascade,
  week_no           int not null,
  pool              int not null,
  achiever_count    int not null,
  reward_per_person int not null,
  finalized_at      timestamptz not null default now(),
  primary key (season_id, week_no)
);

create table if not exists public.settlement_lines (
  season_id       int not null,
  week_no         int not null,
  enrollment_id   bigint not null references public.enrollments(id),
  goal            int not null,
  challenge_count int not null,
  deduction       int not null,
  reward          int not null,
  paid            boolean not null default false,
  primary key (season_id, week_no, enrollment_id),
  foreign key (season_id, week_no) references public.weekly_settlements(season_id, week_no) on delete cascade
);

-- 다음 시즌 참가 여부 받기(운영자가 시즌마다 설정)
alter table public.seasons add column if not exists rejoin_from  date;   -- 응답 시작일
alter table public.seasons add column if not exists rejoin_until date;   -- 응답 마감일
alter table public.seasons add column if not exists rejoin_fee   int not null default 0;   -- 재참가비
alter table public.seasons add column if not exists pay_info     text;   -- 입금 계좌 안내
alter table public.seasons add column if not exists pay_due      date;   -- 입금 기한
alter table public.seasons add column if not exists refund_on    date;   -- 보증금 반환일

create table if not exists public.season_intents (
  participant_id uuid not null references public.participants(id) on delete cascade,
  season_id      int  not null references public.seasons(id) on delete cascade,   -- 이 시즌이 끝난 뒤 다음 시즌에 대한 응답
  answer         text not null check (answer in ('join', 'leave')),
  answered_at    timestamptz not null default now(),
  primary key (participant_id, season_id)
);

-- 계정 연결(인스타그램·스레드)과 성과 수집. 이 표들은 서버 함수(Edge Function)만 읽고 씁니다.
create table if not exists public.social_accounts (
  participant_id uuid not null references public.participants(id) on delete cascade,
  platform       text not null check (platform in ('instagram', 'threads')),
  account_id     text not null,
  username       text,
  bio            text,
  access_token   text not null,           -- 화면으로는 절대 내려보내지 않음
  connected_at   timestamptz not null default now(),
  last_sync_at   timestamptz,
  last_error     text,
  primary key (participant_id, platform)
);
create table if not exists public.connect_states (
  state          text primary key,
  participant_id uuid not null references public.participants(id) on delete cascade,
  platform       text not null,
  created_at     timestamptz not null default now()
);
create table if not exists public.follower_snapshots (
  participant_id uuid not null references public.participants(id) on delete cascade,
  platform       text not null,
  day            date not null,
  followers      int  not null,
  primary key (participant_id, platform, day)
);
create table if not exists public.media_metrics (
  participant_id uuid not null references public.participants(id) on delete cascade,
  platform       text not null,
  media_id       text not null,
  permalink      text,
  caption        text,
  media_type     text,
  posted_at      timestamptz,
  metrics        jsonb not null default '{}'::jsonb,
  fetched_at     timestamptz not null default now(),
  primary key (platform, media_id)
);

insert into public.seasons (number, starts_on, ends_on)
values (2, '2026-11-29', '2026-12-26')
on conflict (number) do nothing;

-- 3) 내부 함수 (이름이 _ 로 시작, 외부 호출 불가) ------------------------
create or replace function public._current_season() returns public.seasons
language plpgsql stable security definer set search_path = public, extensions as $$
declare s seasons;
begin
  select * into s from seasons where starts_on <= _today() order by starts_on desc limit 1;
  if not found then select * into s from seasons order by starts_on asc limit 1; end if;
  return s;
end $$;

create or replace function public._auth(p_token text) returns public.participants
language plpgsql stable security definer set search_path = public, extensions as $$
declare r participants;
begin
  select p.* into r from sessions x join participants p on p.id = x.participant_id
  where x.token = p_token and x.expires_at > now();
  if not found then raise exception '로그인이 만료됐어요. 다시 로그인해 주세요.'; end if;
  return r;
end $$;

create or replace function public._admin(p_token text) returns public.participants
language plpgsql stable security definer set search_path = public, extensions as $$
declare r participants;
begin
  r := _auth(p_token);
  if not r.is_admin then raise exception '운영자만 할 수 있는 작업이에요.'; end if;
  return r;
end $$;

create or replace function public._new_session(p_pid uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(24), 'hex');
begin
  delete from sessions where expires_at < now();
  insert into sessions (token, participant_id, expires_at) values (t, p_pid, now() + interval '30 days');
  return t;
end $$;

-- 랠리: 확정된 주차 기준 연속 달성 주 수 (현재, 최고)
create or replace function public._rally(p_pid uuid) returns table (cur int, best int)
language plpgsql stable security definer set search_path = public, extensions as $$
declare r record; c int := 0; b int := 0;
begin
  for r in
    select l.enrollment_id is not null as has, l.challenge_count, l.goal
    from weekly_settlements w
    join seasons s on s.id = w.season_id
    left join (select sl.* from settlement_lines sl
               join enrollments e on e.id = sl.enrollment_id
               where e.participant_id = p_pid) l
      on l.season_id = w.season_id and l.week_no = w.week_no
    order by s.number, w.week_no
  loop
    if r.has and r.challenge_count >= r.goal then
      c := c + 1; if c > b then b := c; end if;
    else c := 0; end if;
  end loop;
  cur := c; best := b; return next;
end $$;

-- 주간 정산 계산 (확정 전 현재값)
create or replace function public._settle_rows(p_season int, p_week int)
returns table (eid bigint, pid uuid, name text, goal int, cnt int, deduction int, ok boolean)
language sql stable security definer set search_path = public, extensions as $$
  select e.id, p.id, p.name, e.weekly_goal, c.n::int,
         (greatest(e.weekly_goal - c.n, 0) * (s.weekly_deposit / e.weekly_goal))::int,
         c.n >= e.weekly_goal
  from enrollments e
  join participants p on p.id = e.participant_id
  join seasons s on s.id = e.season_id
  cross join lateral (select count(*) n from posts po
                      where po.enrollment_id = e.id and po.week_no = p_week and po.counts_for_challenge) c
  where e.season_id = p_season
$$;

create or replace function public._week_json(p_season int, p_week int) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare s seasons; ws weekly_settlements; v_lines json; v_pool int; v_n int;
begin
  select * into s from seasons where id = p_season;
  select * into ws from weekly_settlements where season_id = p_season and week_no = p_week;
  if found then
    select coalesce(json_agg(json_build_object('eid', l.enrollment_id, 'name', p.name, 'goal', l.goal,
             'count', l.challenge_count, 'deduction', l.deduction, 'ok', l.challenge_count >= l.goal,
             'reward', l.reward, 'paid', l.paid) order by p.name), '[]'::json) into v_lines
    from settlement_lines l
    join enrollments e on e.id = l.enrollment_id
    join participants p on p.id = e.participant_id
    where l.season_id = p_season and l.week_no = p_week;
    return json_build_object('week', p_week, 'final', true, 'closed', true, 'started', true,
      'finalized_at', ws.finalized_at, 'pool', ws.pool, 'achievers', ws.achiever_count,
      'reward', ws.reward_per_person, 'lines', v_lines);
  end if;
  select coalesce(sum(r.deduction), 0)::int, (count(*) filter (where r.ok))::int into v_pool, v_n
  from _settle_rows(p_season, p_week) r;
  select coalesce(json_agg(json_build_object('eid', r.eid, 'name', r.name, 'goal', r.goal, 'count', r.cnt,
           'deduction', r.deduction, 'ok', r.ok,
           'reward', case when r.ok and v_n > 0 then v_pool / v_n else 0 end, 'paid', false)
           order by r.name), '[]'::json) into v_lines
  from _settle_rows(p_season, p_week) r;
  return json_build_object('week', p_week, 'final', false,
    'closed', now() >= _deadline(s.starts_on, p_week),
    'started', _today() >= s.starts_on + (p_week - 1) * 7,
    'pool', v_pool, 'achievers', v_n,
    'reward', case when v_n > 0 then v_pool / v_n else 0 end, 'lines', v_lines);
end $$;

-- 인증 저장(추가/수정) 공통 로직. 모든 규칙 검증은 여기서 한다.
create or replace function public._put_post(
  p_admin boolean, p_pid uuid, p_post bigint, p_url text, p_on date, p_type text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  o posts; s seasons; e enrollments;
  v_owner uuid := p_pid; v_url text; v_norm text; v_type text; v_week int; v_counts boolean;
  v_id bigint; v_total int; v_lvl int; v_seen int; v_wc int; v_other uuid;
begin
  if p_post is not null then
    select * into o from posts where id = p_post;
    if not found then raise exception '인증 기록을 찾지 못했어요. 새로고침 후 다시 시도해 주세요.'; end if;
    if not p_admin and o.participant_id <> p_pid then raise exception '본인의 인증만 고칠 수 있어요.'; end if;
    v_owner := o.participant_id;
    if not p_admin then
      select se.* into s from enrollments en join seasons se on se.id = en.season_id where en.id = o.enrollment_id;
      if now() >= _deadline(s.starts_on, o.week_no) then
        raise exception '이미 마감된 주의 인증이에요. 수정이 필요하면 운영자에게 알려 주세요.';
      end if;
    end if;
  end if;

  v_url := btrim(coalesce(nullif(btrim(coalesce(p_url, '')), ''), o.url, ''));
  v_norm := _norm_url(v_url);
  if v_norm is null or char_length(v_url) > 500 then
    raise exception '링크를 확인해 주세요. https:// 로 시작하는 게시물 주소를 붙여넣으면 돼요.';
  end if;

  p_on := coalesce(p_on, o.published_on, _today());
  if p_on > _today() then raise exception '발행일은 오늘까지만 고를 수 있어요.'; end if;
  select * into s from seasons where p_on between starts_on and ends_on;
  if not found then raise exception '챌린지 기간 밖의 날짜예요. 발행일을 다시 골라 주세요.'; end if;
  v_week := (p_on - s.starts_on) / 7 + 1;
  if not p_admin and now() >= _deadline(s.starts_on, v_week) then
    raise exception '그 주의 인증은 마감됐어요(일요일 낮 12시). 빠진 인증은 운영자에게 알려 주세요.';
  end if;

  select * into e from enrollments where participant_id = v_owner and season_id = s.id;
  if not found then raise exception '먼저 시즌 참가 설정을 해 주세요.'; end if;

  v_type := coalesce(nullif(p_type, ''),
                     case when p_post is not null and v_norm = o.url_normalized then o.content_type end,
                     _classify(v_norm));
  if not (v_type = any(_types())) then raise exception '콘텐츠 유형을 다시 골라 주세요.'; end if;

  select participant_id into v_other from posts
  where url_normalized = v_norm and (p_post is null or id <> p_post);
  if found then
    if v_other = v_owner then
      raise exception '이미 인증한 링크예요. 새로 발행한 콘텐츠의 링크를 넣어 주세요.';
    else
      raise exception '다른 참가자가 이미 인증한 링크예요. 링크를 다시 확인해 주세요.';
    end if;
  end if;

  v_counts := v_type = any(e.goal_types);
  if p_post is null then
    insert into posts (participant_id, enrollment_id, url, url_normalized, content_type, published_on, week_no, counts_for_challenge)
    values (v_owner, e.id, v_url, v_norm, v_type, p_on, v_week, v_counts) returning id into v_id;
  else
    update posts set enrollment_id = e.id, url = v_url, url_normalized = v_norm, content_type = v_type,
      published_on = p_on, week_no = v_week, counts_for_challenge = v_counts where id = p_post;
    v_id := p_post;
  end if;

  select count(*) into v_wc from posts where enrollment_id = e.id and week_no = v_week and counts_for_challenge;
  select count(*) into v_total from posts where participant_id = v_owner;
  v_lvl := _level(v_total);
  select level_seen into v_seen from participants where id = v_owner;
  if v_lvl > v_seen then update participants set level_seen = v_lvl where id = v_owner; end if;

  return json_build_object('id', v_id, 'week', v_week, 'counts', v_counts, 'type', v_type,
    'week_count', v_wc, 'goal', e.weekly_goal, 'total', v_total, 'level', v_lvl,
    'level_up', (v_lvl > v_seen) and not p_admin and p_post is null);
end $$;

create or replace function public._check_goal(p_types text[], p_goal int) returns void
language plpgsql immutable as $$
begin
  if p_types is null or coalesce(array_length(p_types, 1), 0) < 1 then
    raise exception '목표 콘텐츠 유형을 하나 이상 골라 주세요.';
  end if;
  if not (p_types <@ _types()) then raise exception '콘텐츠 유형을 다시 골라 주세요.'; end if;
  if p_goal is null or p_goal < 1 or p_goal > 5 then raise exception '주간 목표는 1~5회 중에서 골라 주세요.'; end if;
end $$;

-- 4) 참가자용 함수 -------------------------------------------------------
create or replace function public.name_status(p_name text) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare r participants;
begin
  select * into r from participants where _norm(name) = _norm(p_name);
  if not found then return 'new'; end if;
  if r.pin_hash is null then return 'reset'; end if;
  return 'pin';
end $$;

create or replace function public.register(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')); r participants;
begin
  if char_length(v_name) < 1 or char_length(v_name) > 12 then raise exception '이름은 1~12자로 적어 주세요.'; end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then raise exception 'PIN은 숫자 4자리로 정해 주세요.'; end if;
  if exists (select 1 from participants where _norm(name) = _norm(v_name)) then
    raise exception '이미 등록된 이름이에요. PIN을 입력해 로그인해 주세요.';
  end if;
  insert into participants (name, pin_hash, is_admin)
  values (v_name, crypt(p_pin, gen_salt('bf')), not exists (select 1 from participants))   -- 첫 가입자가 운영자
  returning * into r;
  return json_build_object('token', _new_session(r.id), 'id', r.id, 'name', r.name);
end $$;

-- 실패 횟수를 기록해야 하므로 오류를 던지지 않고 {error}로 돌려준다
create or replace function public.login(p_name text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare r participants; v_left int;
begin
  select * into r from participants where _norm(name) = _norm(p_name);
  if not found then return json_build_object('error', '등록되지 않은 이름이에요. 철자를 확인해 주세요.'); end if;
  if r.locked_until is not null and r.locked_until > now() then
    return json_build_object('error', 'PIN을 여러 번 틀려 잠시 잠겼어요. ' ||
      greatest(1, ceil(extract(epoch from r.locked_until - now()) / 60))::int || '분 뒤에 다시 시도해 주세요.');
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return json_build_object('error', 'PIN은 숫자 4자리예요.'); end if;
  if r.pin_hash is null then
    update participants set pin_hash = crypt(p_pin, gen_salt('bf')), failed_count = 0, locked_until = null where id = r.id;
  elsif r.pin_hash = crypt(p_pin, r.pin_hash) then
    update participants set failed_count = 0, locked_until = null where id = r.id;
  else
    if r.failed_count + 1 >= 5 then
      update participants set failed_count = 0, locked_until = now() + interval '10 minutes' where id = r.id;
      return json_build_object('error', 'PIN을 5번 틀려 10분 동안 잠겼어요. 잊으셨다면 운영자에게 초기화를 요청해 주세요.');
    end if;
    update participants set failed_count = failed_count + 1 where id = r.id;
    v_left := 5 - (r.failed_count + 1);
    return json_build_object('error', 'PIN이 맞지 않아요. ' || v_left || '번 더 시도할 수 있어요.');
  end if;
  return json_build_object('token', _new_session(r.id), 'id', r.id, 'name', r.name);
end $$;

create or replace function public.set_avatar(p_token text, p_avatar text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  if coalesce(p_avatar, '') !~ '^[0-8]-[0-8]$' then raise exception '캐릭터를 다시 골라 주세요.'; end if;
  update participants set avatar = p_avatar where id = me.id;
end $$;

create or replace function public.set_rejoin(p_token text, p_answer text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants; s seasons;
begin
  me := _auth(p_token);
  s := _current_season();
  if s.id is null or s.rejoin_from is null or not (_today() between s.rejoin_from and s.rejoin_until) then
    raise exception '지금은 응답 기간이 아니에요. 변경이 필요하면 운영자에게 알려 주세요.';
  end if;
  if not exists (select 1 from enrollments where participant_id = me.id and season_id = s.id) then
    raise exception '이번 시즌 참가자만 응답할 수 있어요.';
  end if;
  if p_answer not in ('join', 'leave') then raise exception '응답을 다시 골라 주세요.'; end if;
  insert into season_intents (participant_id, season_id, answer) values (me.id, s.id, p_answer)
  on conflict (participant_id, season_id) do update set answer = excluded.answer, answered_at = now();
end $$;

drop function if exists public.set_account_info(text, text, text);
create or replace function public.set_account_info(p_token text, p_intro text, p_target text, p_value text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
  v_i text := nullif(btrim(coalesce(p_intro, '')), '');
  v_t text := nullif(btrim(coalesce(p_target, '')), '');
  v_v text := nullif(btrim(coalesce(p_value, '')), '');
begin
  me := _auth(p_token);
  if greatest(char_length(coalesce(v_i, '')), char_length(coalesce(v_t, '')), char_length(coalesce(v_v, ''))) > 100 then
    raise exception '각 항목은 100자 안으로 적어 주세요.';
  end if;
  update participants set account_intro = v_i, account_target = v_t, account_value = v_v where id = me.id;
end $$;

-- 계정 연결 시작: 일회용 확인값(state)을 발급
create or replace function public.start_connect(p_token text, p_platform text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare me participants; v text := encode(gen_random_bytes(18), 'hex');
begin
  me := _auth(p_token);
  if p_platform not in ('instagram', 'threads') then raise exception '연결할 수 없는 서비스예요.'; end if;
  delete from connect_states where participant_id = me.id or created_at < now() - interval '1 hour';
  insert into connect_states (state, participant_id, platform) values (v, me.id, p_platform);
  return v;
end $$;

-- 내 연결 상태 (토큰은 돌려주지 않음)
create or replace function public.my_social(p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  return (select coalesce(json_agg(json_build_object('platform', a.platform, 'username', a.username,
            'connected_at', a.connected_at, 'last_sync_at', a.last_sync_at, 'last_error', a.last_error,
            'followers', (select f.followers from follower_snapshots f
                          where f.participant_id = a.participant_id and f.platform = a.platform order by f.day desc limit 1),
            'media', (select count(*) from media_metrics m where m.participant_id = a.participant_id and m.platform = a.platform))
          order by a.platform), '[]'::json)
          from social_accounts a where a.participant_id = me.id);
end $$;

-- 성과 리포트: 본인 또는 운영자만
create or replace function public.report(p_token text, p_participant uuid) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare me participants; p participants;
begin
  me := _auth(p_token);
  if me.id <> p_participant and not me.is_admin then raise exception '본인의 리포트만 볼 수 있어요.'; end if;
  select * into p from participants where id = p_participant;
  if not found then raise exception '참가자를 찾지 못했어요.'; end if;
  return json_build_object('username', p.ig_username,
    'ready', exists (select 1 from social_accounts where platform = 'instagram'),
    'followers', (select coalesce(json_agg(json_build_object('day', f.day, 'n', f.followers) order by f.day), '[]'::json)
                  from follower_snapshots f where f.participant_id = p.id and f.platform = 'instagram'),
    'media', (select coalesce(json_agg(x order by x.posted_at desc), '[]'::json) from (
                select m.permalink, m.posted_at, m.media_type as type, (m.metrics->>'likes')::int as likes,
                       (m.metrics->>'comments')::int as comments, (m.metrics->>'views')::int as views
                from media_metrics m where m.participant_id = p.id and m.platform = 'instagram'
                order by m.posted_at desc limit 30) x),
    'updated', (select max(m.fetched_at) from media_metrics m where m.participant_id = p.id and m.platform = 'instagram'));
end $$;

create or replace function public.clear_ig(p_token text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  update participants set ig_username = null where id = me.id;
  delete from follower_snapshots where participant_id = me.id and platform = 'instagram';
  delete from media_metrics      where participant_id = me.id and platform = 'instagram';
end $$;

create or replace function public.disconnect_social(p_token text, p_platform text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  delete from social_accounts where participant_id = me.id and platform = p_platform;
end $$;

create or replace function public.logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from sessions where token = p_token
$$;

create or replace function public.enroll(p_token text, p_goal_types text[], p_weekly_goal int, p_main_channel_url text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me participants; s seasons; e enrollments; v_ch text := nullif(btrim(coalesce(p_main_channel_url, '')), '');
begin
  me := _auth(p_token);
  s := _current_season();
  if s.id is null then raise exception '열려 있는 시즌이 없어요. 운영자에게 문의해 주세요.'; end if;
  if _today() > s.ends_on then raise exception '이번 시즌은 끝났어요. 다음 시즌에서 만나요.'; end if;
  perform _check_goal(p_goal_types, p_weekly_goal);
  if v_ch is not null and (v_ch !~* '^https?://\S+$' or char_length(v_ch) > 300) then
    raise exception '대표 채널 주소는 https:// 로 시작하게 적어 주세요. 비워 둬도 돼요.';
  end if;
  select * into e from enrollments where participant_id = me.id and season_id = s.id;
  if found then
    if _today() >= s.starts_on then
      raise exception '시즌이 시작된 뒤에는 목표를 바꿀 수 없어요. 변경이 필요하면 운영자에게 알려 주세요.';
    end if;
    update enrollments set goal_types = p_goal_types, weekly_goal = p_weekly_goal, main_channel_url = v_ch where id = e.id;
  else
    insert into enrollments (participant_id, season_id, goal_types, weekly_goal, main_channel_url)
    values (me.id, s.id, p_goal_types, p_weekly_goal, v_ch);
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.add_post(p_token text, p_url text, p_published_on date default null, p_content_type text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  return _put_post(false, me.id, null, p_url, p_published_on, p_content_type);
end $$;

create or replace function public.update_post(p_token text, p_post_id bigint, p_url text default null, p_published_on date default null, p_content_type text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  return _put_post(false, me.id, p_post_id, p_url, p_published_on, p_content_type);
end $$;

create or replace function public.delete_post(p_token text, p_post_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants; o posts; s seasons;
begin
  me := _auth(p_token);
  select * into o from posts where id = p_post_id;
  if not found then return; end if;
  if o.participant_id <> me.id then raise exception '본인의 인증만 지울 수 있어요.'; end if;
  select se.* into s from enrollments en join seasons se on se.id = en.season_id where en.id = o.enrollment_id;
  if now() >= _deadline(s.starts_on, o.week_no) then
    raise exception '이미 마감된 주의 인증이에요. 삭제가 필요하면 운영자에게 알려 주세요.';
  end if;
  delete from posts where id = p_post_id;
end $$;

create or replace function public.toggle_cheer(p_token text, p_post_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare me participants; o posts; v_on boolean;
begin
  me := _auth(p_token);
  select * into o from posts where id = p_post_id;
  if not found then raise exception '콘텐츠를 찾지 못했어요. 새로고침 후 다시 시도해 주세요.'; end if;
  if o.participant_id = me.id then raise exception '내 콘텐츠에는 응원을 누를 수 없어요.'; end if;
  delete from cheers where post_id = p_post_id and participant_id = me.id;
  v_on := not found;
  if v_on then insert into cheers (post_id, participant_id) values (p_post_id, me.id); end if;
  return json_build_object('cheered', v_on, 'count', (select count(*) from cheers where post_id = p_post_id));
end $$;

-- 홈 화면에 필요한 값 전부 (안전한 값만)
create or replace function public.get_state(p_token text default null) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  me participants; has_me boolean := false; expired boolean := false; s seasons;
  v_people json := '[]'; v_posts json := '[]'; v_settled json := '[]'; v_me json; v_mine json := '[]';
  v_seasons json; v_season json; v_rejoin json;
begin
  if coalesce(p_token, '') <> '' then
    select p.* into me from sessions x join participants p on p.id = x.participant_id
    where x.token = p_token and x.expires_at > now();
    has_me := found; expired := not found;
  end if;
  s := _current_season();
  select coalesce(json_agg(json_build_object('id', id, 'number', number, 'starts_on', starts_on, 'ends_on', ends_on)
         order by number), '[]'::json) into v_seasons from seasons;

  if s.id is not null then
    v_season := json_build_object('id', s.id, 'number', s.number, 'starts_on', s.starts_on,
                                  'ends_on', s.ends_on, 'weekly_deposit', s.weekly_deposit);
    select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'avatar', p.avatar, 'eid', e.id, 'types', e.goal_types,
             'goal', e.weekly_goal, 'channel', e.main_channel_url,
             'total', (select count(*) from posts po where po.participant_id = p.id),
             'rally', r.cur, 'best', r.best) order by p.name), '[]'::json) into v_people
    from enrollments e join participants p on p.id = e.participant_id
    cross join lateral _rally(p.id) r
    where e.season_id = s.id;

    select coalesce(json_agg(json_build_object('id', po.id, 'pid', po.participant_id, 'url', po.url,
             'type', po.content_type, 'on', po.published_on, 'week', po.week_no, 'counts', po.counts_for_challenge,
             'at', extract(epoch from po.created_at) * 1000,
             'cheers', (select count(*) from cheers c where c.post_id = po.id),
             'cheered', has_me and exists (select 1 from cheers c where c.post_id = po.id and c.participant_id = me.id))
             order by po.created_at desc), '[]'::json) into v_posts
    from posts po join enrollments e on e.id = po.enrollment_id
    where e.season_id = s.id;

    select coalesce(json_agg(json_build_object('week', week_no, 'pool', pool, 'achievers', achiever_count,
             'reward', reward_per_person) order by week_no), '[]'::json) into v_settled
    from weekly_settlements where season_id = s.id;

    if has_me then
      select coalesce(json_agg(json_build_object('week', l.week_no, 'goal', l.goal, 'count', l.challenge_count,
               'deduction', l.deduction, 'reward', l.reward, 'paid', l.paid) order by l.week_no), '[]'::json) into v_mine
      from settlement_lines l join enrollments e on e.id = l.enrollment_id
      where l.season_id = s.id and e.participant_id = me.id;
    end if;
  end if;

  if has_me then
    v_me := json_build_object('id', me.id, 'name', me.name, 'avatar', me.avatar, 'is_admin', me.is_admin,
      'enrolled', s.id is not null and exists (select 1 from enrollments where participant_id = me.id and season_id = s.id),
      'prev', (select json_build_object('types', e.goal_types, 'goal', e.weekly_goal, 'channel', e.main_channel_url)
               from enrollments e join seasons se on se.id = e.season_id
               where e.participant_id = me.id order by se.number desc limit 1));
    if s.id is not null and s.rejoin_from is not null
       and exists (select 1 from enrollments where participant_id = me.id and season_id = s.id) then
      v_rejoin := json_build_object('from', s.rejoin_from, 'until', s.rejoin_until, 'fee', s.rejoin_fee,
        'pay_info', s.pay_info, 'pay_due', s.pay_due, 'refund_on', s.refund_on,
        'open', _today() between s.rejoin_from and s.rejoin_until,
        'answer', (select answer from season_intents where participant_id = me.id and season_id = s.id));
    end if;
  end if;

  return json_build_object('now_ms', extract(epoch from now()) * 1000, 'today', _today(),
    'season', v_season, 'seasons', v_seasons, 'people', v_people, 'posts', v_posts,
    'settled', v_settled, 'me', v_me, 'mine', v_mine, 'rejoin', v_rejoin, 'expired', expired);
end $$;

-- 개인 아카이브 (누구나 조회)
create or replace function public.get_profile(p_participant uuid) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare p participants; v_posts json; v_seasons json; rc int; rb int;
begin
  select * into p from participants where id = p_participant;
  if not found then raise exception '참가자를 찾지 못했어요. 새로고침 후 다시 시도해 주세요.'; end if;
  select cur, best into rc, rb from _rally(p.id);
  select coalesce(json_agg(json_build_object('id', po.id, 'url', po.url, 'type', po.content_type,
           'on', po.published_on, 'week', po.week_no, 'counts', po.counts_for_challenge, 'season', se.number,
           'open', now() < _deadline(se.starts_on, po.week_no),
           'cheers', (select count(*) from cheers c where c.post_id = po.id))
           order by po.published_on desc, po.created_at desc), '[]'::json) into v_posts
  from posts po join enrollments e on e.id = po.enrollment_id join seasons se on se.id = e.season_id
  where po.participant_id = p.id;

  select coalesce(json_agg(json_build_object('number', se.number, 'goal', e.weekly_goal, 'types', e.goal_types,
           'channel', e.main_channel_url,
           'weeks', (select json_agg(json_build_object('week', g.w, 'final', l.enrollment_id is not null,
                       'ok', case when l.enrollment_id is not null then l.challenge_count >= l.goal
                                  when _today() >= se.starts_on + (g.w - 1) * 7 then
                                    (select count(*) from posts po where po.enrollment_id = e.id
                                       and po.week_no = g.w and po.counts_for_challenge) >= e.weekly_goal
                                  else null end) order by g.w)
                     from generate_series(1, (se.ends_on - se.starts_on + 1) / 7) g(w)
                     left join settlement_lines l
                       on l.enrollment_id = e.id and l.season_id = se.id and l.week_no = g.w))
           order by se.number desc), '[]'::json) into v_seasons
  from enrollments e join seasons se on se.id = e.season_id
  where e.participant_id = p.id;

  return json_build_object('id', p.id, 'name', p.name, 'avatar', p.avatar,
    'intro', p.account_intro, 'target', p.account_target, 'value', p.account_value,
    'total', (select count(*) from posts where participant_id = p.id),
    'cheers', (select count(*) from cheers c join posts po on po.id = c.post_id where po.participant_id = p.id),
    'rally', rc, 'best', rb, 'posts', v_posts, 'seasons', v_seasons);
end $$;

-- 5) 운영자용 함수 (세션 토큰으로 is_admin 확인) ---------------------------
create or replace function public.admin_data(p_token text, p_season_id int default null) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare me participants; s seasons; v_parts json; v_weeks json; v_seasons json;
begin
  me := _admin(p_token);
  if p_season_id is null then s := _current_season(); else select * into s from seasons where id = p_season_id; end if;
  select coalesce(json_agg(json_build_object('id', id, 'number', number, 'starts_on', starts_on, 'ends_on', ends_on)
         order by number), '[]'::json) into v_seasons from seasons;
  select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name, 'avatar', p.avatar, 'is_admin', p.is_admin,
           'has_pin', p.pin_hash is not null,
           'intent', (select i.answer from season_intents i where i.participant_id = p.id and i.season_id = s.id),
           'e', (select json_build_object('id', e.id, 'types', e.goal_types, 'goal', e.weekly_goal, 'channel', e.main_channel_url)
                 from enrollments e where e.participant_id = p.id and e.season_id = s.id)) order by p.name), '[]'::json)
    into v_parts from participants p;
  if s.id is not null then
    select coalesce(json_agg(_week_json(s.id, g.w) order by g.w), '[]'::json) into v_weeks
    from generate_series(1, (s.ends_on - s.starts_on + 1) / 7) g(w);
  end if;
  return json_build_object('season', case when s.id is null then null else
      json_build_object('id', s.id, 'number', s.number, 'starts_on', s.starts_on, 'ends_on', s.ends_on, 'weekly_deposit', s.weekly_deposit,
        'rejoin_from', s.rejoin_from, 'rejoin_until', s.rejoin_until, 'rejoin_fee', s.rejoin_fee,
        'pay_info', s.pay_info, 'pay_due', s.pay_due, 'refund_on', s.refund_on) end,
    'seasons', v_seasons, 'participants', v_parts, 'weeks', coalesce(v_weeks, '[]'::json));
end $$;

create or replace function public.admin_create_season(p_token text, p_number int, p_starts_on date, p_ends_on date) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  if p_number is null or p_starts_on is null or p_ends_on is null then raise exception '번호, 시작일, 종료일을 모두 채워 주세요.'; end if;
  if extract(dow from p_starts_on) <> 0 then raise exception '시작일은 일요일이어야 해요. (주간 기준이 일~토예요)'; end if;
  if p_ends_on < p_starts_on or (p_ends_on - p_starts_on + 1) % 7 <> 0 then
    raise exception '종료일은 토요일이어야 해요. (기간이 7일 단위로 떨어져야 해요)';
  end if;
  if exists (select 1 from seasons where number = p_number) then raise exception '이미 있는 시즌 번호예요.'; end if;
  if exists (select 1 from seasons where p_starts_on <= ends_on and p_ends_on >= starts_on) then
    raise exception '다른 시즌과 기간이 겹쳐요. 날짜를 다시 확인해 주세요.';
  end if;
  insert into seasons (number, starts_on, ends_on) values (p_number, p_starts_on, p_ends_on);
end $$;

create or replace function public.admin_set_rejoin(p_token text, p_season_id int, p_from date, p_until date,
  p_fee int, p_pay_info text, p_pay_due date, p_refund_on date) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  if (p_from is null) <> (p_until is null) then raise exception '응답 시작일과 마감일을 둘 다 넣어 주세요.'; end if;
  if p_from is not null and p_until < p_from then raise exception '응답 마감일이 시작일보다 빨라요.'; end if;
  if coalesce(p_fee, 0) < 0 then raise exception '재참가비는 0원 이상으로 적어 주세요.'; end if;
  update seasons set rejoin_from = p_from, rejoin_until = p_until, rejoin_fee = coalesce(p_fee, 0),
    pay_info = nullif(btrim(coalesce(p_pay_info, '')), ''), pay_due = p_pay_due, refund_on = p_refund_on
  where id = p_season_id;
end $$;

create or replace function public.admin_set_enrollment(p_token text, p_participant uuid, p_season_id int,
  p_goal_types text[], p_weekly_goal int, p_main_channel_url text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_eid bigint;
begin
  perform _admin(p_token);
  perform _check_goal(p_goal_types, p_weekly_goal);
  insert into enrollments (participant_id, season_id, goal_types, weekly_goal, main_channel_url)
  values (p_participant, p_season_id, p_goal_types, p_weekly_goal, nullif(btrim(coalesce(p_main_channel_url, '')), ''))
  on conflict (participant_id, season_id) do update
    set goal_types = excluded.goal_types, weekly_goal = excluded.weekly_goal, main_channel_url = excluded.main_channel_url
  returning id into v_eid;
  update posts set counts_for_challenge = content_type = any(p_goal_types) where enrollment_id = v_eid;
end $$;

create or replace function public.admin_reset_pin(p_token text, p_participant uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  update participants set pin_hash = null, failed_count = 0, locked_until = null where id = p_participant;
  delete from sessions where participant_id = p_participant;
end $$;

create or replace function public.admin_remove_participant(p_token text, p_participant uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _admin(p_token);
  if me.id = p_participant then raise exception '본인 계정은 삭제할 수 없어요.'; end if;
  if exists (select 1 from settlement_lines l join enrollments e on e.id = l.enrollment_id where e.participant_id = p_participant) then
    raise exception '정산이 확정된 기록이 있는 참가자는 삭제할 수 없어요.';
  end if;
  delete from participants where id = p_participant;
end $$;

create or replace function public.admin_put_post(p_token text, p_participant uuid, p_post_id bigint,
  p_url text default null, p_published_on date default null, p_content_type text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  return _put_post(true, p_participant, p_post_id, p_url, p_published_on, p_content_type);
end $$;

create or replace function public.admin_delete_post(p_token text, p_post_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  delete from posts where id = p_post_id;
end $$;

create or replace function public.admin_finalize(p_token text, p_season_id int, p_week_no int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare s seasons; v_pool int; v_n int; v_reward int;
begin
  perform _admin(p_token);
  select * into s from seasons where id = p_season_id;
  if not found or p_week_no < 1 or p_week_no > (s.ends_on - s.starts_on + 1) / 7 then
    raise exception '주차를 다시 확인해 주세요.';
  end if;
  if now() < _deadline(s.starts_on, p_week_no) then
    raise exception '아직 마감 전이에요. 일요일 낮 12시 이후에 확정할 수 있어요.';
  end if;
  if exists (select 1 from weekly_settlements where season_id = p_season_id and week_no = p_week_no) then
    raise exception '이미 확정된 주예요. 다시 계산하려면 먼저 확정을 풀어 주세요.';
  end if;
  select coalesce(sum(deduction), 0)::int, (count(*) filter (where ok))::int into v_pool, v_n
  from _settle_rows(p_season_id, p_week_no);
  v_reward := case when v_n > 0 then v_pool / v_n else 0 end;       -- 1원 미만 버림
  insert into weekly_settlements (season_id, week_no, pool, achiever_count, reward_per_person)
  values (p_season_id, p_week_no, v_pool, v_n, v_reward);
  insert into settlement_lines (season_id, week_no, enrollment_id, goal, challenge_count, deduction, reward)
  select p_season_id, p_week_no, r.eid, r.goal, r.cnt, r.deduction, case when r.ok then v_reward else 0 end
  from _settle_rows(p_season_id, p_week_no) r;
end $$;

create or replace function public.admin_unfinalize(p_token text, p_season_id int, p_week_no int) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  delete from weekly_settlements where season_id = p_season_id and week_no = p_week_no;   -- lines는 함께 삭제
end $$;

create or replace function public.admin_set_paid(p_token text, p_season_id int, p_week_no int, p_enrollment_id bigint, p_paid boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  update settlement_lines set paid = p_paid
  where season_id = p_season_id and week_no = p_week_no and enrollment_id = p_enrollment_id;
end $$;

-- 5-b) 소재 제안 (나의 이야기 → 매주 소재 5개) -------------------------------
create table if not exists public.topic_ideas (
  id             bigserial primary key,
  participant_id uuid not null references public.participants(id) on delete cascade,
  batch          uuid not null,
  title          text not null,
  link           text,
  format         text,
  opener         text,
  status         text not null default 'new' check (status in ('new', 'adopted', 'done')),
  created_at     timestamptz not null default now()
);
create index if not exists topic_ideas_who on public.topic_ideas (participant_id, created_at desc);

drop function if exists public.set_account_story(text, text, text, text, text);
create or replace function public.set_account_story(p_token text, p_why text, p_now text, p_changed text, p_asked text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
  v_w text := nullif(btrim(coalesce(p_why, '')), '');
  v_n text := nullif(btrim(coalesce(p_now, '')), '');
  v_c text := nullif(btrim(coalesce(p_changed, '')), '');
  v_a text := nullif(btrim(coalesce(p_asked, '')), '');
  v_j jsonb := '{}'::jsonb;
begin
  me := _auth(p_token);
  if greatest(char_length(coalesce(v_w, '')), char_length(coalesce(v_n, '')), char_length(coalesce(v_c, '')), char_length(coalesce(v_a, ''))) > 300 then
    raise exception '각 항목은 300자 안으로 적어 주세요.';
  end if;
  if v_w is not null then v_j := v_j || jsonb_build_object('why', v_w); end if;
  if v_n is not null then v_j := v_j || jsonb_build_object('now', v_n); end if;
  if v_c is not null then v_j := v_j || jsonb_build_object('changed', v_c); end if;
  if v_a is not null then v_j := v_j || jsonb_build_object('asked', v_a); end if;
  update participants set account_story = case when v_j = '{}'::jsonb then null else v_j end where id = me.id;
end $$;

-- 내 이야기와 받은 소재(최근 30일). 본인만 볼 수 있다.
create or replace function public.my_ideas(p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  return json_build_object(
    'story', coalesce(me.account_story, '{}'::jsonb),
    'used', (select count(distinct batch) from topic_ideas
             where participant_id = me.id and (created_at at time zone 'Asia/Seoul')::date = _today()),
    'limit', 3,
    'ideas', (select coalesce(json_agg(x order by x.at desc, x.id), '[]'::json) from (
                select t.id, t.batch, t.title, t.link, t.format, t.opener, t.status, t.created_at as at
                from topic_ideas t where t.participant_id = me.id and t.created_at > now() - interval '30 days') x));
end $$;

-- 소재 상태 바꾸기: new(기본) / adopted(이걸로 쓸게요) / done(발행했어요)
create or replace function public.set_idea_status(p_token text, p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me participants;
begin
  me := _auth(p_token);
  if p_status not in ('new', 'adopted', 'done') then raise exception '상태를 다시 골라 주세요.'; end if;
  update topic_ideas set status = p_status where id = p_id and participant_id = me.id;
  if not found then raise exception '소재를 찾지 못했어요. 새로고침 후 다시 시도해 주세요.'; end if;
end $$;

-- 6) 보안 규칙 -----------------------------------------------------------
-- 테이블은 전부 잠그고(RLS, 권한 회수), 위의 공개 함수로만 읽고 쓴다.
alter table public.participants       enable row level security;
alter table public.seasons            enable row level security;
alter table public.enrollments        enable row level security;
alter table public.posts              enable row level security;
alter table public.cheers             enable row level security;
alter table public.sessions           enable row level security;
alter table public.weekly_settlements enable row level security;
alter table public.settlement_lines   enable row level security;
alter table public.season_intents     enable row level security;
alter table public.social_accounts    enable row level security;
alter table public.connect_states     enable row level security;
alter table public.follower_snapshots enable row level security;
alter table public.media_metrics      enable row level security;
alter table public.topic_ideas        enable row level security;
revoke all on public.social_accounts, public.connect_states, public.follower_snapshots, public.media_metrics from anon, authenticated;
grant all on public.social_accounts, public.connect_states, public.follower_snapshots, public.media_metrics to service_role;
revoke all on public.topic_ideas from anon, authenticated;
grant all on public.topic_ideas to service_role;
grant usage, select on sequence public.topic_ideas_id_seq to service_role;

revoke all on public.participants, public.seasons, public.enrollments, public.posts, public.cheers,
  public.sessions, public.weekly_settlements, public.settlement_lines, public.season_intents from anon, authenticated;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.proname like '\_%' or p.proname like 'admin\_%'
           or p.proname in ('name_status','register','login','logout','set_avatar','set_rejoin','set_account_info','set_account_story','my_ideas','set_idea_status','start_connect','my_social','disconnect_social','report','clear_ig','enroll','add_post','update_post',
                            'delete_post','toggle_cheer','get_state','get_profile'))
  loop
    if f.proname like '\_%' then
      execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    else
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
