-- ═══════════════════════════════════════════════════════════════
-- PlanUP 팀 공지사항 — 개인별 확인 체크
-- 팀 시트는 한 번에 한 명만 편집 가능한 잠금 구조라, 공지 확인 체크까지 그 잠금을 따르면
-- 편집 권한이 없는 사람은 확인 버튼조차 못 누르게 된다. 그래서 확인 체크만큼은 잠금과 무관하게
-- 이 함수로 직접 처리한다 (지금 누가 편집 중이어도 상관없이 눌림).
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- (supabase-multi-team.sql 을 먼저 실행해서 shared_data 테이블이 있어야 함)
-- ═══════════════════════════════════════════════════════════════

create or replace function toggle_notice_confirm(p_team_id text, p_notice_id text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  notices jsonb;
  new_notices jsonb := '[]'::jsonb;
  item jsonb;
  confirmed jsonb;
  has_name boolean;
  new_confirmed jsonb;
begin
  select coalesce(data->'cal_notices', '[]'::jsonb) into notices from shared_data where id = p_team_id;

  for item in select * from jsonb_array_elements(notices)
  loop
    if item->>'id' = p_notice_id then
      confirmed := coalesce(item->'confirmedBy', '[]'::jsonb);
      has_name := exists(select 1 from jsonb_array_elements(confirmed) c where c->>'name' = p_name);
      if has_name then
        select coalesce(jsonb_agg(c), '[]'::jsonb) into new_confirmed
          from jsonb_array_elements(confirmed) c where c->>'name' <> p_name;
      else
        new_confirmed := confirmed || jsonb_build_array(jsonb_build_object('name', p_name, 'at', floor(extract(epoch from now())*1000)));
      end if;
      item := jsonb_set(item, '{confirmedBy}', new_confirmed);
    end if;
    new_notices := new_notices || jsonb_build_array(item);
  end loop;

  update shared_data
     set data = jsonb_set(coalesce(data,'{}'::jsonb), '{cal_notices}', new_notices),
         updated_at = now(),
         updated_by_name = p_name
   where id = p_team_id;

  return new_notices;
end;
$$;

grant execute on function toggle_notice_confirm(text, text, text) to authenticated;
