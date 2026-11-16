// 매일툭챌린지 · 계정 연결 서버 함수 (Supabase Edge Function, 이름: social)
// 필요한 비밀값(Secrets): META_APP_ID, META_APP_SECRET, SYNC_KEY
// 설정: 이 함수는 "Verify JWT"를 꺼야 합니다. (Meta가 로그인 없이 호출하기 때문)
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = "https://onzoo2.github.io/dailytuk/";
const GRAPH = "https://graph.facebook.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const db = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
const APP_ID = Deno.env.get("META_APP_ID");
const APP_SECRET = Deno.env.get("META_APP_SECRET");
const SYNC_KEY = Deno.env.get("SYNC_KEY");

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

// 인스타그램 계정 하나의 팔로워 수와 최근 게시물 지표를 받아 저장
async function syncInstagram(acc) {
  const tok = acc.access_token, ig = acc.account_id, pid = acc.participant_id;
  try {
    const prof = await graph("/" + ig + "?fields=username,followers_count,media_count,biography", tok);
    await db.from("follower_snapshots").upsert({ participant_id: pid, platform: "instagram", day: todayKST(), followers: prof.followers_count ?? 0 });
    const list = await graph("/" + ig + "/media?fields=id,caption,media_type,media_product_type,permalink,timestamp,like_count,comments_count&limit=30", tok);
    for (const m of list.data || []) {
      const metrics = { likes: m.like_count ?? null, comments: m.comments_count ?? null };
      for (const set of ["views,reach,saved,shares,total_interactions", "reach,saved,shares", "reach,saved"]) {
        try {
          const ins = await graph("/" + m.id + "/insights?metric=" + set, tok);
          for (const d of ins.data || []) metrics[d.name] = d.values && d.values[0] ? d.values[0].value : null;
          break;
        } catch (_e) { /* 이 게시물 유형에서 지원하지 않는 지표면 더 적은 묶음으로 다시 시도 */ }
      }
      await db.from("media_metrics").upsert({
        participant_id: pid, platform: "instagram", media_id: m.id, permalink: m.permalink || null,
        caption: (m.caption || "").slice(0, 2200), media_type: m.media_product_type || m.media_type || null,
        posted_at: m.timestamp || null, metrics, fetched_at: new Date().toISOString(),
      });
    }
    await db.from("social_accounts").update({ username: prof.username || acc.username, bio: prof.biography || null,
      last_sync_at: new Date().toISOString(), last_error: null }).eq("participant_id", pid).eq("platform", "instagram");
    return null;
  } catch (e) {
    const msg = String(e && e.message || e).slice(0, 300);
    await db.from("social_accounts").update({ last_error: msg }).eq("participant_id", pid).eq("platform", "instagram");
    return msg;
  }
}

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type", "access-control-allow-methods": "POST, OPTIONS" };
function json(body, status) {
  return new Response(JSON.stringify(body), { status: status || 200, headers: { ...CORS, "content-type": "application/json" } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/social/, "");
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  // 0) 시험용: 로그인 없이 다른 프로페셔널 계정의 공개 수치 조회 (운영자만)
  if (path.startsWith("/discover")) {
    try {
      const body = await req.json().catch(() => ({}));
      const { data: ses } = await db.from("sessions").select("participant_id, expires_at").eq("token", body.token || "").maybeSingle();
      if (!ses || new Date(ses.expires_at).getTime() < Date.now()) return json({ error: "로그인이 만료됐어요. 다시 로그인해 주세요." }, 401);
      const { data: me } = await db.from("participants").select("is_admin").eq("id", ses.participant_id).maybeSingle();
      if (!me || !me.is_admin) return json({ error: "운영자만 쓸 수 있어요." }, 403);
      const { data: acc } = await db.from("social_accounts").select("*").eq("participant_id", ses.participant_id).eq("platform", "instagram").maybeSingle();
      if (!acc) return json({ error: "먼저 운영자 본인의 인스타그램을 연결해 주세요." }, 400);
      const name = String(body.username || "").trim().replace(/^@/, "");
      if (!/^[A-Za-z0-9._]{1,30}$/.test(name)) return json({ error: "인스타그램 아이디를 다시 확인해 주세요." }, 400);
      const tries = [
        "username,followers_count,media_count,media.limit(5){permalink,timestamp,media_type,media_product_type,like_count,comments_count,view_count}",
        "username,followers_count,media_count,media.limit(5){permalink,timestamp,media_type,like_count,comments_count}",
        "username,followers_count,media_count",
      ];
      const errors = [];
      for (const f of tries) {
        try {
          const r = await graph("/" + acc.account_id + "?fields=" + encodeURIComponent("business_discovery.username(" + name + "){" + f + "}"), acc.access_token);
          return json({ ok: true, fields: f, result: r.business_discovery || r, earlier_errors: errors });
        } catch (e) { errors.push(String(e && e.message || e)); }
      }
      return json({ error: "조회하지 못했어요.", details: errors });
    } catch (e) {
      return json({ error: "서버 오류: " + String(e && e.message || e) }, 500);
    }
  }

  // 1) 인스타그램 연결 후 Meta가 되돌려 보내는 주소
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

      // 연결된 인스타그램 계정 찾기 (통합 로그인 → 페이지 연결 방식 순서로 시도)
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

      const acc = { participant_id: st.participant_id, platform: "instagram", account_id: String(ig.id), username: ig.username || null,
        access_token: tok, connected_at: new Date().toISOString(), last_error: null };
      const up = await db.from("social_accounts").upsert(acc);
      if (up.error) return back("error", "저장 실패: " + up.error.message);
      const syncErr = await syncInstagram(acc);
      return back("ok", syncErr ? "연결은 됐지만 첫 수집에 실패했어요: " + syncErr : "instagram");
    } catch (e) {
      return back("error", "서버 오류: " + String(e && e.message || e));
    }
  }

  // 2) 전체 계정 수집 (매일 한 번 자동 호출용). 헤더 x-sync-key 가 SYNC_KEY 와 같아야 함
  if (path.startsWith("/sync")) {
    if (!SYNC_KEY || req.headers.get("x-sync-key") !== SYNC_KEY) return new Response("forbidden", { status: 403 });
    const { data: accs } = await db.from("social_accounts").select("*").eq("platform", "instagram");
    const out = [];
    for (const a of accs || []) out.push({ username: a.username, error: await syncInstagram(a) });
    return new Response(JSON.stringify(out), { headers: { "content-type": "application/json" } });
  }

  return new Response("ok");
});
