-- ═══════════════════════════════════════════════════════════════
-- PlanUP 컨택포인트 (실 전체 공유) 초기화
-- 팀마다 따로 있던 "매체 컨택포인트"를 광고1본부 3실 전체가 같이 보는 하나로 옮긴다.
-- 이미 supabase-multi-team.sql 을 실행해서 shared_data / team_settings / 잠금 함수가
-- 있는 상태를 전제로 한다 (이 SQL은 그 위에 얹는 것).
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- ═══════════════════════════════════════════════════════════════

-- 1) 'sil' 행 준비 (없으면 빈 값으로 생성 — 잠금 기능은 이미 shared_data 테이블에 있는 걸 그대로 씀)
insert into shared_data (id, data) values ('sil', '{}'::jsonb) on conflict (id) do nothing;

-- 2) 9팀이 그동안 모아둔 매체 컨택포인트를 실 공유 데이터로 옮긴다.
--    9team 행의 data->cal_contacts 를 sil 행의 data->contacts 로 복사한다.
--    (이미 sil.data.contacts 에 값이 들어있는 경우 — 즉 이 스크립트를 이미 한 번 실행한 경우 — 덮어쓰지 않는다)
update shared_data
   set data = jsonb_set(
     data,
     '{contacts}',
     coalesce((select data->'cal_contacts' from shared_data where id = '9team'), '[]'::jsonb)
   )
 where id = 'sil'
   and (data->'contacts' is null or data->'contacts' = '[]'::jsonb);

-- 3) 8팀/9팀/10팀 공유 데이터에서는 담당자 목록을 더 이상 쓰지 않으므로 비워준다
--    (계정 등 나머지 데이터는 그대로 둔다)
update shared_data set data = data - 'cal_contacts' where id in ('8team', '9team', '10team');
