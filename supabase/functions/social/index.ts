// 매일툭챌린지 · 성과 수집 서버 함수 (Supabase Edge Function, 이름: social)
// 필요한 비밀값(Secrets): META_APP_ID, META_APP_SECRET, (자동 수집을 켤 때) SYNC_KEY
// 설정: 이 함수는 "Verify JWT"를 꺼야 합니다.
//
// 동작 방식
//  - 운영자가 본인 인스타그램을 한 번 연결한다(/instagram). 이 연결의 권한으로
//  - 참가자가 적어 둔 인스타그램 아이디의 공개 수치를 조회해 저장한다(/track, /sync).
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = "https://onzoo2.github.io/dailytuk/";
const GRAPH = "https://graph.facebook.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const db = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
const APP_ID = Deno.env.get("META_APP_ID");
const APP_SECRET = Deno.env.get("META_APP_SECRET");
const SYNC_KEY = Deno.env.get("SYNC_KEY");

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type", "access-control-allow-methods": "POST, OPTIONS" };
function json(body, status) {
  return new Response(JSON.stringify(body), { status: status || 200, headers: { ...CORS, "content-type": "application/json" } });
}
function back(kind, msg) {
  return Response.redirect(SITE + "#social/" + kind + "/" + encodeURIComponent(String(msg || "").slice(0, 300)), 302);
}
function todayKST() {
  return new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);
}
async function graph(path, token) {
  const sep = path.includes("?") ? "&" : "?";
  const res = await fetch(GRAPH + path + sep + "access_token=" + encodeURIComponent(token));
  const j = await res.json().catch(() => ({}));
  if (!res.ok || j.error) throw new Error((j.error && j.error.message) || "Meta 응답 오류 " + res.status);
  return j;
}
async function sessionUser(token) {
  const { data: ses } = await db.from("sessions").select("participant_id, expires_at").eq("token", token || "").maybeSingle();
  if (!ses || new Date(ses.expires_at).getTime() < Date.now()) return null;
  const { data: p } = await db.from("participants").select("id, name, is_admin, ig_username").eq("id", ses.participant_id).maybeSingle();
  return p || null;
}
// 조회에 쓸 연결(운영자가 연결한 인스타그램)
async function reader() {
  const { data } = await db.from("social_accounts").select("*").eq("platform", "instagram").order("connected_at", { ascending: true });
  return (data || [])[0] || null;
}

// 아이디 하나의 공개 수치(팔로워, 최근 게시물 반응)를 받아 저장
async function trackOne(pid, username, rd, reset) {
  const sets = [
    "username,followers_count,media_count,media.limit(30){permalink,timestamp,media_type,media_product_type,like_count,comments_count,view_count}",
    "username,followers_count,media_count,media.limit(30){permalink,timestamp,media_type,media_product_type,like_count,comments_count}",
  ];
  let bd = null, lastErr = "";
  for (const f of sets) {
    try {
      const r = await graph("/" + rd.account_id + "?fields=" + encodeURIComponent("business_discovery.username(" + username + "){" + f + "}"), rd.access_token);
      bd = r.business_discovery; break;
    } catch (e) { lastErr = String(e && e.message || e); }
  }
  if (!bd) throw new Error(lastErr || "조회하지 못했어요.");
  if (reset) {                       // 다른 계정의 기록이 섞이지 않게, 아이디가 바뀌면 이전 기록을 지움
    await db.from("follower_snapshots").delete().eq("participant_id", pid).eq("platform", "instagram");
    await db.from("media_metrics").delete().eq("participant_id", pid).eq("platform", "instagram");
  }
  const a = await db.from("follower_snapshots").upsert({ participant_id: pid, platform: "instagram", day: todayKST(), followers: bd.followers_count ?? 0 });
  if (a.error) throw new Error("저장 실패: " + a.error.message);
  const rows = ((bd.media && bd.media.data) || []).map((m) => ({
    participant_id: pid, platform: "instagram", media_id: String(m.id), permalink: m.permalink || null, caption: null,
    media_type: m.media_product_type === "REELS" ? "REELS" : (m.media_type || null), posted_at: m.timestamp || null,
    metrics: { likes: m.like_count ?? null, comments: m.comments_count ?? null, views: m.view_count ?? null },
    fetched_at: new Date().toISOString(),
  }));
  if (rows.length) {
    const b = await db.from("media_metrics").upsert(rows);
    if (b.error) throw new Error("저장 실패: " + b.error.message);
  }
  return { username: bd.username, followers: bd.followers_count ?? 0, media: rows.length };
}
async function syncAll() {
  const rd = await reader();
  if (!rd) return { error: "운영자의 인스타그램 연결이 없어요." };
  const { data: people } = await db.from("participants").select("id, name, ig_username").not("ig_username", "is", null);
  const out = [];
  for (const p of people || []) {
    try { out.push({ name: p.name, ...(await trackOne(p.id, p.ig_username, rd, false)) }); }
    catch (e) { out.push({ name: p.name, error: String(e && e.message || e) }); }
  }
  return { ok: true, day: todayKST(), results: out };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/social/, "");
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  // 1) 참가자가 인스타그램 아이디를 등록 (로그인·권한 허용 없이 공개 수치만 조회)
  if (path.startsWith("/track")) {
    try {
      const body = await req.json().catch(() => ({}));
      const me = await sessionUser(body.token);
      if (!me) return json({ error: "로그인이 만료됐어요. 다시 로그인해 주세요." }, 401);
      const name = String(body.username || "").trim().replace(/^@/, "").toLowerCase();
      if (!/^[a-z0-9._]{1,30}$/.test(name)) return json({ error: "인스타그램 아이디를 다시 확인해 주세요. (@ 뒤의 영문 아이디)" }, 400);
      const rd = await reader();
      if (!rd) return json({ error: "아직 수집 준비가 안 됐어요. 운영자에게 알려 주세요." }, 400);
      let sum;
      try { sum = await trackOne(me.id, name, rd, me.ig_username !== name); }
      catch (e) {
        return json({ error: "이 아이디의 수치를 불러오지 못했어요. 아이디 철자와, 프로페셔널(비즈니스·크리에이터) 계정인지 확인해 주세요.", detail: String(e && e.message || e) }, 400);
      }
      const up = await db.from("participants").update({ ig_username: name }).eq("id", me.id);
      if (up.error) return json({ error: "저장 실패: " + up.error.message }, 500);
      return json({ ok: true, ...sum });
    } catch (e) { return json({ error: "서버 오류: " + String(e && e.message || e) }, 500); }
  }

  // 2) 전체 수집: 운영자가 버튼으로 실행하거나, 매일 자동 호출(x-sync-key)
  if (path.startsWith("/sync")) {
    let allowed = !!SYNC_KEY && req.headers.get("x-sync-key") === SYNC_KEY;
    if (!allowed) {
      const body = await req.json().catch(() => ({}));
      const me = await sessionUser(body.token);
      allowed = !!(me && me.is_admin);
    }
    if (!allowed) return json({ error: "운영자만 실행할 수 있어요." }, 403);
    try { return json(await syncAll()); } catch (e) { return json({ error: "서버 오류: " + String(e && e.message || e) }, 500); }
  }

  // 3) 운영자의 인스타그램 연결 후 Meta가 되돌려 보내는 주소
  if (path.startsWith("/instagram")) {
    try {
      const code = url.searchParams.get("code"), state = url.searchParams.get("state");
      const denied = url.searchParams.get("error_description") || url.searchParams.get("error");
      if (denied) return back("error", "연결이 취소됐어요. (" + denied + ")");
      if (!code || !state) return back("error", "연결 정보가 비어 있어요. 다시 시도해 주세요.");
      if (!APP_ID || !APP_SECRET) return back("error", "서버에 META_APP_ID / META_APP_SECRET 이 설정되지 않았어요.");
      const { data: st } = await db.from("connect_states").select("*").eq("state", state).maybeSingle();
      if (!st || Date.now() - new Date(st.created_at).getTime() > 15 * 60e3) return back("error", "연결 시간이 지났어요. 다시 시도해 주세요.");
      await db.from("connect_states").delete().eq("state", state);

      const redirect = SUPABASE_URL + "/functions/v1/social/instagram";
      const tr = await fetch(GRAPH + "/oauth/access_token?client_id=" + APP_ID + "&client_secret=" + encodeURIComponent(APP_SECRET) +
        "&redirect_uri=" + encodeURIComponent(redirect) + "&code=" + encodeURIComponent(code));
      const tj = await tr.json().catch(() => ({}));
      if (!tj.access_token) return back("error", "토큰 교환 실패: " + ((tj.error && tj.error.message) || tr.status));
      const tok = tj.access_token;

      let ig = null, detail = "";
      try {
        const a = await graph("/me/assigned_instagram_accounts?fields=id,username", tok);
        if (a.data && a.data[0]) ig = a.data[0];
      } catch (e) { detail += " assigned: " + e.message; }
      if (!ig) {
        try {
          const p = await graph("/me/accounts?fields=instagram_business_account{id,username}", tok);
          const hit = (p.data || []).find((x) => x.instagram_business_account);
          if (hit) ig = hit.instagram_business_account;
        } catch (e) { detail += " pages: " + e.message; }
      }
      if (!ig) return back("error", "연결된 인스타그램 계정을 찾지 못했어요." + detail);

      const up = await db.from("social_accounts").upsert({ participant_id: st.participant_id, platform: "instagram", account_id: String(ig.id),
        username: ig.username || null, access_token: tok, connected_at: new Date().toISOString(), last_sync_at: new Date().toISOString(), last_error: null });
      if (up.error) return back("error", "저장 실패: " + up.error.message);
      return back("ok", "instagram");
    } catch (e) { return back("error", "서버 오류: " + String(e && e.message || e)); }
  }

  return new Response("ok", { headers: CORS });
});
