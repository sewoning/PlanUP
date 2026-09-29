-- PlanUP 메일 시트 (개인 전용)
-- 아웃룩은 내 PC 안의 파일이라 웹앱이 직접 못 읽는다. 그래서 로컬 수집 스크립트가
-- 당일 메일의 "헤더"만 뽑아 여기에 올리고, 앱은 이 테이블만 본다.
-- 본문 전체와 첨부파일 내용은 올리지 않는다 (미리보기 200자, 첨부는 파일명만).

create table if not exists mail_items (
  id          uuid primary key default gen_random_uuid(),
  -- 기본값을 auth.uid()로 두면 수집 스크립트가 user_id를 따로 실어 보낼 필요가 없다.
  -- (RLS의 with check가 어차피 본인 것만 허용하므로 남의 id를 넣는 것도 막힌다)
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,

  -- 아웃룩이 메일마다 부여하는 고유값. 스크립트를 여러 번 돌려도 같은 메일이
  -- 중복으로 쌓이지 않게 (user_id, entry_id)로 묶는다.
  entry_id    text not null,

  direction   text not null check (direction in ('received', 'sent')),
  subject     text,
  from_name   text,
  from_email  text,
  to_line     text,
  sent_at     timestamptz not null,
  folder      text,
  has_attach  boolean not null default false,
  attachments text[] not null default '{}',

  -- 새로 온 내용만 담는다. 아래에 인용되어 딸려오는 이전 메일들은 수집기가 걷어낸다
  -- (실측: 하루 82건 174만 자 → 13만 자, 93% 감소). 첨부파일 내용은 여전히 올리지 않는다.
  body        text,
  unread      boolean not null default false,
  synced_at   timestamptz not null default now(),

  unique (user_id, entry_id)
);

-- 처음엔 본문 앞 200자만 담아서 칼럼 이름이 preview였다. 이제 새 본문 전체를 담으므로
-- 이름을 맞춰준다 — 이미 만들어 쓰던 테이블도 그대로 따라오게 조건부로 바꾼다.
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_name = 'mail_items' and column_name = 'preview'
  ) then
    alter table mail_items rename column preview to body;
  end if;
end
$$;

-- 목록은 항상 "내 메일을 최신순으로"라서 이 조합으로만 조회한다
create index if not exists mail_items_user_sent_idx on mail_items (user_id, sent_at desc);

alter table mail_items enable row level security;

-- 본인 것만. 팀 시트와 달리 공유 개념이 없다 — 같은 팀이어도 남의 메일은 안 보인다.
drop policy if exists "mail_items_own" on mail_items;
create policy "mail_items_own" on mail_items
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- 당일치만 두기로 했으므로, 수집 스크립트가 매번 지난 메일을 지운다.
-- 스크립트가 한동안 안 돌아도 찌꺼기가 남지 않도록 함수로 만들어 둔다.
create or replace function prune_old_mail(p_keep_days int default 1)
returns int
language plpgsql
security invoker
as $$
declare
  n int;
begin
  delete from mail_items
   where user_id = auth.uid()
     and sent_at < (now() at time zone 'Asia/Seoul')::date - (p_keep_days - 1)
  returning 1 into n;
  get diagnostics n = row_count;
  return n;
end;
$$;
