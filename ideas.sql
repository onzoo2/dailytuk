-- 매일툭챌린지 · 소재 제안 추가분 (기존 데이터는 그대로 두고, 아래만 새로 만들어요)
-- Supabase → SQL Editor 에 통째로 붙여넣고 Run 을 한 번 누르세요. 여러 번 눌러도 안전해요.

alter table public.participants add column if not exists account_story jsonb;  -- 나의 이야기(본인에게만 보임)

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


alter table public.topic_ideas enable row level security;
revoke all on public.topic_ideas from anon, authenticated;
grant all on public.topic_ideas to service_role;
grant usage, select on sequence public.topic_ideas_id_seq to service_role;

grant execute on function public.set_account_story(text, text, text, text, text) to anon, authenticated;
grant execute on function public.my_ideas(text) to anon, authenticated;
grant execute on function public.set_idea_status(text, bigint, text) to anon, authenticated;

notify pgrst, 'reload schema';
