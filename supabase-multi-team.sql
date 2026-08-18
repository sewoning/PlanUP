-- ═══════════════════════════════════════════════════════════════
-- PlanUP 팀 여러 개 지원 (광고8팀 / 광고9팀 / 광고10팀)
-- 이전에 supabase-shared-sheet.sql / supabase-team-password.sql 을
-- 실행해서 팀이 하나("team")였던 걸 3팀 구조로 옮긴다.
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- ═══════════════════════════════════════════════════════════════

-- 0) 필요한 테이블이 아직 없으면 만든다 (이전 SQL을 안 돌렸어도 이 파일 하나로 되게)
create extension if not exists pgcrypto;

create table if not exists shared_data (
  id              text primary key,
  data            jsonb not null default '{}'::jsonb,
  locked_by       uuid,
  locked_by_name  text,
  locked_at       timestamptz,
  updated_at      timestamptz default now(),
  updated_by_name text
);
alter table shared_data enable row level security;
drop policy if exists "shared_data read"  on shared_data;
create policy "shared_data read"  on shared_data for select to authenticated using (true);
drop policy if exists "shared_data write" on shared_data;
create policy "shared_data write" on shared_data for update to authenticated using (true) with check (true);

create table if not exists team_settings (
  id            text primary key,
  password_hash text not null
);
alter table team_settings enable row level security;
-- select/insert/update 정책을 의도적으로 하나도 안 만든다 (직접 조회·수정 전면 차단, 아래 함수로만 비교)

-- 1) 기존에 팀이 하나였을 때 쓰던 행("team")이 있으면 광고9팀 몫으로 옮긴다
--    (이미 입력해둔 공유 데이터가 있다면 안 날아가게)
update shared_data   set id = '9team' where id = 'team' and not exists (select 1 from shared_data where id = '9team');
update team_settings set id = '9team' where id = 'team' and not exists (select 1 from team_settings where id = '9team');

-- 2) 팀별 공유 데이터 행 준비 (없으면 빈 값으로 생성)
insert into shared_data (id, data) values ('8team',  '{}'::jsonb) on conflict (id) do nothing;
insert into shared_data (id, data) values ('9team',  '{}'::jsonb) on conflict (id) do nothing;
insert into shared_data (id, data) values ('10team', '{}'::jsonb) on conflict (id) do nothing;

-- 3) 팀별 비밀번호 설정 — 아래 세 줄의 '여기에_...' 부분을 실제 비밀번호로 바꿔서 실행하세요.
--    (다시 실행하면 그때마다 새로 입력한 값으로 바뀌어요. 광고9팀 비밀번호를 이미 정해두셨다면 같은 값을 넣어주세요)
insert into team_settings (id, password_hash) values ('8team',  crypt('여기에_광고8팀_비밀번호',  gen_salt('bf')))
  on conflict (id) do update set password_hash = excluded.password_hash;
insert into team_settings (id, password_hash) values ('9team',  crypt('여기에_광고9팀_비밀번호',  gen_salt('bf')))
  on conflict (id) do update set password_hash = excluded.password_hash;
insert into team_settings (id, password_hash) values ('10team', crypt('여기에_광고10팀_비밀번호', gen_salt('bf')))
  on conflict (id) do update set password_hash = excluded.password_hash;

-- 4) 잠금/비밀번호 함수를 팀 하나 전용에서 "어느 팀인지"를 받는 형태로 교체
drop function if exists acquire_shared_lock(text, boolean);
drop function if exists heartbeat_shared_lock();
drop function if exists release_shared_lock();
drop function if exists verify_team_password(text);

create or replace function acquire_shared_lock(p_team_id text, p_name text, p_force boolean default false)
returns shared_data
language plpgsql
security definer
set search_path = public
as $$
declare
  r shared_data;
begin
  update shared_data
     set locked_by      = auth.uid(),
         locked_by_name = p_name,
         locked_at      = now()
   where id = p_team_id
     and (p_force
          or locked_by is null
          or locked_by = auth.uid()
          or locked_at < now() - interval '2 minutes')
  returning * into r;

  if r.id is null then
    select * into r from shared_data where id = p_team_id;
  end if;

  return r;
end;
$$;

create or replace function heartbeat_shared_lock(p_team_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update shared_data set locked_at = now()
   where id = p_team_id and locked_by = auth.uid();
$$;

create or replace function release_shared_lock(p_team_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update shared_data
     set locked_by = null, locked_by_name = null, locked_at = null
   where id = p_team_id and locked_by = auth.uid();
$$;

create or replace function verify_team_password(p_team_id text, p_password text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select password_hash = crypt(p_password, password_hash)
  from team_settings where id = p_team_id;
$$;

grant execute on function acquire_shared_lock(text, text, boolean) to authenticated;
grant execute on function heartbeat_shared_lock(text) to authenticated;
grant execute on function release_shared_lock(text)   to authenticated;
grant execute on function verify_team_password(text, text) to authenticated;
