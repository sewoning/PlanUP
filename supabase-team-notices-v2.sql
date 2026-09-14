-- ═══════════════════════════════════════════════════════════════
-- PlanUP 공지사항 안정화 + 팀 저장 방식을 "전체 교체"에서 "병합"으로 변경
--
-- 문제 1 (데이터 유실 위험): 팀/컨택포인트 저장은 지금까지 .update({data: 전체객체})
--   로 data 컬럼을 통째로 덮어썼다. 클라이언트가 들고 있는 state가 어느 필드 하나를
--   빼먹고 보내면(예전에 매체 컨택포인트가 이렇게 통째로 날아간 적 있음) 그 필드가
--   서버에서도 같이 사라진다. save_team_data()는 병합(jsonb ||)으로 바꿔서, 보내지 않은
--   필드는 서버에 있던 값 그대로 남게 한다.
--
-- 문제 2 (공지 확인 경쟁 상태): 공지 확인(toggle_notice_confirm)은 잠금과 무관하게 즉시
--   서버에 반영되는데, 팀 시트를 편집 중인 사람의 로컬 상태는 그 변경을 모른 채로 있다가
--   다음 자동저장 때 자기 로컬의 오래된 공지 목록으로 덮어쓸 위험이 있었다. 공지사항 자체를
--   일반 저장 경로(stateToData)에서 완전히 빼고, 추가/삭제까지도 전용 함수로 처리해서
--   "누가 지금 편집 중인지"와 완전히 무관하게 만든다 — 읽기 전용으로 보고 있는 사람도
--   공지를 등록·삭제·확인할 수 있게 됨 (팀 시트 전체 잠금과 별개로 항상 가능).
--
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- (supabase-multi-team.sql, supabase-team-notices.sql 을 먼저 실행해서
--  shared_data 테이블과 toggle_notice_confirm 함수가 있어야 함)
-- ═══════════════════════════════════════════════════════════════

-- 팀/컨택포인트 저장을 "병합"으로: 보낸 필드만 갱신하고 나머지(cal_notices 등)는 그대로 둔다.
-- 편집 권한(잠금)을 쥔 사람만 쓸 수 있도록 locked_by = auth.uid() 조건은 그대로 유지한다.
create or replace function save_team_data(p_team_id text, p_data jsonb, p_name text)
returns void
language sql
security definer
set search_path = public
as $$
  update shared_data
     set data = coalesce(data, '{}'::jsonb) || p_data,
         updated_at = now(),
         updated_by_name = p_name,
         locked_at = now()
   where id = p_team_id and locked_by = auth.uid();
$$;
grant execute on function save_team_data(text, jsonb, text) to authenticated;

-- 공지 추가 — 잠금과 무관하게 누구나 가능 (배열에 항목 하나 추가)
create or replace function add_notice(p_team_id text, p_notice jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  notices jsonb;
begin
  select coalesce(data->'cal_notices', '[]'::jsonb) into notices from shared_data where id = p_team_id;
  notices := notices || jsonb_build_array(p_notice);
  update shared_data
     set data = jsonb_set(coalesce(data,'{}'::jsonb), '{cal_notices}', notices),
         updated_at = now(),
         updated_by_name = p_notice->>'createdBy'
   where id = p_team_id;
  return notices;
end;
$$;
grant execute on function add_notice(text, jsonb) to authenticated;

-- 공지 삭제 — 잠금과 무관하게 누구나 가능
create or replace function delete_notice(p_team_id text, p_notice_id text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  notices jsonb;
  new_notices jsonb;
begin
  select coalesce(data->'cal_notices', '[]'::jsonb) into notices from shared_data where id = p_team_id;
  select coalesce(jsonb_agg(item), '[]'::jsonb) into new_notices
    from jsonb_array_elements(notices) item where item->>'id' <> p_notice_id;
  update shared_data
     set data = jsonb_set(coalesce(data,'{}'::jsonb), '{cal_notices}', new_notices),
         updated_at = now(),
         updated_by_name = p_name
   where id = p_team_id;
  return new_notices;
end;
$$;
grant execute on function delete_notice(text, text, text) to authenticated;
