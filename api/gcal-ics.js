// 구글 캘린더 iCal 동기화용 프록시. 브라우저에서 calendar.google.com을 직접 fetch하면
// CORS로 막히기 때문에, 우리 서버(Vercel)를 거쳐 대신 가져와 반환한다.
// (예전엔 무료 공개 프록시 api.allorigins.win을 썼는데, 여러 명이 동시에 쓰면
// 레이트리밋에 걸려 사람마다 되고 안 되고가 갈리는 문제가 있었음)
//
// ?team=1 이면 팀 공유 시트용 요청. 팀 캘린더의 "비공개 주소"는 그것만 알면 누구나
// 일정을 볼 수 있는 비밀값이라, 코드/클라이언트에 두지 않고 TEAM_GCAL_URL 환경변수로만 둔다.
// 이 경우 로그인한 사용자인지 확인한 뒤에만 내려준다.

const SUPABASE_URL = 'https://awtdpyoiecymhnwjvtki.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_GgvVhU2ecDXearjojyz-6Q_Yxlnp-TB';

// Supabase 액세스 토큰이 실제로 유효한지 확인
async function isLoggedIn(req) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) return false;
  try {
    const resp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` }
    });
    return resp.ok;
  } catch (e) {
    return false;
  }
}

module.exports = async (req, res) => {
  let url;

  if (req.query.team) {
    if (!(await isLoggedIn(req))) {
      res.status(401).send('login required');
      return;
    }
    url = process.env.TEAM_GCAL_URL;
    if (!url) {
      res.status(500).send('TEAM_GCAL_URL is not configured');
      return;
    }
  } else {
    url = req.query.url;
    if (!url || typeof url !== 'string' || !/^https:\/\/calendar\.google\.com\//.test(url)) {
      res.status(400).send('invalid url');
      return;
    }
  }

  try {
    const upstream = await fetch(url, { headers: { 'User-Agent': 'PlanUP-Sync/1.0' } });
    if (!upstream.ok) {
      res.status(upstream.status).send('upstream error');
      return;
    }
    const text = await upstream.text();
    res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.status(200).send(text);
  } catch (e) {
    res.status(502).send('fetch failed: ' + e.message);
  }
};
