-- ═══════════════════════════════════════════════════════════════
-- PlanUP 실 시트 (구글시트 대체)
-- supabase-multi-team.sql을 먼저 실행해서 shared_data/team_settings/
-- 잠금 함수들이 이미 있는 상태여야 합니다.
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 실행하세요.
-- ═══════════════════════════════════════════════════════════════

-- 실 시트는 팀들과 같은 shared_data 테이블을 쓰지만 비밀번호가 없다.
-- (team_settings에 'sil' 행을 안 만들어서, 애초에 verify_team_password로 잠글 수 없게 해둠 — 앱 쪽에서도 비번 절차를 안 거침)
insert into shared_data (id, data) values ('sil', '{}'::jsonb)
on conflict (id) do nothing;
