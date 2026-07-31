// 구글 캘린더 iCal 동기화용 프록시. 브라우저에서 calendar.google.com을 직접 fetch하면
// CORS로 막히기 때문에, 우리 서버(Vercel)를 거쳐 대신 가져와 반환한다.
// (예전엔 무료 공개 프록시 api.allorigins.win을 썼는데, 여러 명이 동시에 쓰면
// 레이트리밋에 걸려 사람마다 되고 안 되고가 갈리는 문제가 있었음)
module.exports = async (req, res) => {
  const url = req.query.url;
  if (!url || typeof url !== 'string' || !/^https:\/\/calendar\.google\.com\//.test(url)) {
    res.status(400).send('invalid url');
    return;
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
