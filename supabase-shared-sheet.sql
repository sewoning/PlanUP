-- ═══════════════════════════════════════════════════════════════
-- PlanUP 팀 공유 시트 (엑셀식 잠금: 한 번에 한 명만 편집)
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- ═══════════════════════════════════════════════════════════════

-- 1) 공유 데이터 테이블 (팀 전체가 함께 보는 한 덩어리)
create table if not exists shared_data (
  id              text primary key,
  data            jsonb not null default '{}'::jsonb,
  locked_by       uuid,          -- 지금 편집 중인 사람 (auth.uid())
  locked_by_name  text,          -- 화면에 보여줄 닉네임
  locked_at       timestamptz,   -- 편집 중 신호(하트비트) 시각
  updated_at      timestamptz default now(),
  updated_by_name text
);

-- 공유 시트는 하나만 사용
insert into shared_data (id, data) values ('team', '{}'::jsonb)
on conflict (id) do nothing;

-- 2) 로그인한 사람은 누구나 읽고 쓸 수 있게 (편집 제한은 아래 잠금 로직이 담당)
alter table shared_data enable row level security;

drop policy if exists "shared_data read"  on shared_data;
create policy "shared_data read"  on shared_data for select to authenticated using (true);

drop policy if exists "shared_data write" on shared_data;
create policy "shared_data write" on shared_data for update to authenticated using (true) with check (true);

-- 3) 잠금 획득
--    아무도 안 쓰고 있거나 / 내가 이미 갖고 있거나 / 2분간 신호가 없으면(=자리 비움) 잠금을 가져온다.
--    p_force = true 면 강제로 뺏어온다 ("강제로 편집 권한 가져오기" 버튼).
create or replace function acquire_shared_lock(p_name text, p_force boolean default false)
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
   where id = 'team'
     and (p_force
          or locked_by is null
          or locked_by = auth.uid()
          or locked_at < now() - interval '2 minutes')
  returning * into r;

  -- 잠금을 못 잡았으면 (다른 사람이 편집 중) 현재 상태를 그대로 돌려줘서 읽기 전용으로 열게 한다
  if r.id is null then
    select * into r from shared_data where id = 'team';
  end if;

  return r;
end;
$$;

-- 4) 편집 중 신호 (30초마다 호출 — 이게 끊기면 2분 뒤 잠금이 자동으로 풀림)
create or replace function heartbeat_shared_lock()
returns void
language sql
security definer
set search_path = public
as $$
  update shared_data set locked_at = now()
   where id = 'team' and locked_by = auth.uid();
$$;

-- 5) 잠금 해제 (내 잠금만 풀 수 있음)
create or replace function release_shared_lock()
returns void
language sql
security definer
set search_path = public
as $$
  update shared_data
     set locked_by = null, locked_by_name = null, locked_at = null
   where id = 'team' and locked_by = auth.uid();
$$;

grant execute on function acquire_shared_lock(text, boolean) to authenticated;
grant execute on function heartbeat_shared_lock() to authenticated;
grant execute on function release_shared_lock()   to authenticated;
