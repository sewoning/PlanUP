-- ═══════════════════════════════════════════════════════════════
-- PlanUP 팀 공유 시트 비밀번호
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- 팀 비밀번호는 해시로만 저장하고, RLS로 직접 조회를 막는다.
-- (아래 verify 함수만 security definer로 우회해서 비교함 — 클라이언트는 절대 비밀번호 원문/해시를 볼 수 없음)
create table if not exists team_settings (
  id            text primary key,
  password_hash text not null
);
alter table team_settings enable row level security;
-- 의도적으로 select/insert/update 정책을 하나도 만들지 않는다 (직접 조회·수정 전면 차단)

-- ── 팀 비밀번호를 처음 설정하거나 바꿀 때 아래 한 줄만 고쳐서 다시 실행하세요 ──
insert into team_settings (id, password_hash)
values ('team', crypt('여기에_팀_비밀번호_입력', gen_salt('bf')))
on conflict (id) do update set password_hash = excluded.password_hash;

create or replace function verify_team_password(p_password text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select password_hash = crypt(p_password, password_hash)
  from team_settings where id = 'team';
$$;

grant execute on function verify_team_password(text) to authenticated;
