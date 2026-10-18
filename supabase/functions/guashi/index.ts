// 六爻卦館：卦師解卦伺服器（Supabase Edge Function）
// 驗證登入 → 扣卦數／追問次數 → 呼叫 Claude → 存紀錄
// 需要的密鑰（Supabase 後台 Edge Functions → Secrets）：ANTHROPIC_API_KEY
// SUPABASE_URL、SUPABASE_ANON_KEY、SUPABASE_SERVICE_ROLE_KEY 由 Supabase 自動提供
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MSG: Record<string, string> = {
  no_invest: "本館不判斷投資標的、股票或買賣時機，請改問整體財運（占類選「財運·財運」）。這次沒有扣卦數。",
  no_plan: "還沒有訂閱方案，請先選方案並完成轉帳。",
  expired: "方案已到期，請續訂。",
  quota: "本期卦數已用完，可以升級方案（從開通日重新計算 30 天）。",
  daily_cap: "今天已達合理使用上限，明天再來。",
  followup_limit: "這一卦的追問次數已用完，可以重新起一卦。",
};

const INVEST_RE = /股票|股市|個股|投資|基金|虛擬幣|加密貨幣|比特幣|幣圈|期貨|選擇權|權證|ETF|外匯|進場|出場|買進|賣出|標的|當沖|融資|融券/i;
const GUARD = `【固定規則，優先於下面的規則書】
1. 不回答投資標的、股票、基金、虛擬幣、期貨或任何買賣時機的問題；遇到這類問題只談整體財運，並說明本館不做投資判斷。
2. 盤面附的【作用檢查表】是系統依規則算好的；每一個動爻、暗動、日月沖合、旺衰都要交代，不可漏看。
3. 靜爻之間不生不剋；變爻只回頭作用在自己的動爻。

`;

const FORMAT = `【輸出格式】
先用一句話給結論（吉、凶、或有條件），再分四段，每段用「## 」開頭當標題：
## 用神狀態
## 關鍵爻與動變
## 應期
## 建議
「關鍵爻與動變」要照【作用檢查表】逐條交代：每個動爻、暗動生剋沖合了誰，變爻回頭怎麼作用，日月沖合了誰；旺衰以檢查表為準。不會成就不給應期，改說原因。
全文 500 字以內，白話繁體中文。`;

async function callClaude(model: string, maxTokens: number, rules: string, messages: { role: string; content: string }[]) {
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": Deno.env.get("ANTHROPIC_API_KEY") ?? "",
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: maxTokens,
      // 規則書每次都一樣，標記快取：第二次以後只收約 5% 費用
      system: [{ type: "text", text: GUARD + rules, cache_control: { type: "ephemeral" } }],
      messages,
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error("claude_error:" + (j?.error?.message ?? r.status));
  return (j.content ?? []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const auth = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "login", message: "請先登入。" }, 401);
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }

  const { data: priv } = await admin.from("private_settings").select("key,value");
  const S = Object.fromEntries((priv ?? []).map((r: { key: string; value: string }) => [r.key, r.value]));
  const model = S.model || "claude-sonnet-5-5";
  const maxTokens = parseInt(S.max_tokens || "1500", 10);
  const rules = S.rules || "你是一位六爻卦師。";
  const { data: pub } = await admin.from("public_settings").select("value").eq("key", "followup_limit").maybeSingle();
  const followLimit = parseInt(pub?.value ?? "3", 10);

  // ── 解一卦 ──
  if (body.action === "read") {
    const chart = String(body.chart ?? "").slice(0, 12000);
    if (!chart) return json({ error: "bad_request" }, 400);
    if (INVEST_RE.test(String(body.question ?? ""))) return json({ error: "no_invest", message: MSG.no_invest }, 400);
    const { data: rid, error } = await admin.rpc("consume_reading", {
      uid: user.id, q: String(body.question ?? "").slice(0, 500), cat: String(body.category ?? "").slice(0, 50), chart_text: chart, model_name: model,
    });
    if (error) {
      const code = Object.keys(MSG).find((k) => error.message.includes(k)) ?? "error";
      return json({ error: code, message: MSG[code] ?? "系統忙碌，請稍後再試。" }, 402);
    }
    try {
      const text = await callClaude(model, maxTokens, rules, [{ role: "user", content: `【盤面】\n${chart}\n\n${FORMAT}` }]);
      await admin.from("readings").update({ answer: text }).eq("id", rid);
      const { data: p } = await admin.from("profiles").select("used,plan").eq("id", user.id).single();
      return json({ text, reading_id: rid, used: p?.used, followups_left: followLimit });
    } catch (e) {
      await admin.rpc("refund_reading", { rid });   // 解卦失敗就把這一卦退回
      return json({ error: "claude", message: "卦師暫時沒有回應，這一卦沒有扣次數，請稍後再試。", detail: String(e) }, 502);
    }
  }

  // ── 追問 ──
  if (body.action === "ask") {
    const rid = Number(body.reading_id);
    const q = String(body.question ?? "").trim().slice(0, 500);
    if (!rid || !q) return json({ error: "bad_request" }, 400);
    if (INVEST_RE.test(q)) return json({ error: "no_invest", message: "本館不判斷投資標的或買賣時機，可以改問整體財運。這次沒有扣追問次數。" }, 400);
    const { data: r } = await admin.from("readings").select("*").eq("id", rid).eq("user_id", user.id).maybeSingle();
    if (!r || !r.answer) return json({ error: "not_found", message: "找不到這一卦。" }, 404);
    if (r.followups >= followLimit) return json({ error: "followup_limit", message: MSG.followup_limit }, 402);
    const thread = (r.thread ?? []) as { q: string; a: string }[];
    const messages: { role: string; content: string }[] = [
      { role: "user", content: `【盤面】\n${r.chart}\n\n${FORMAT}` },
      { role: "assistant", content: r.answer },
    ];
    for (const t of thread.slice(-4)) messages.push({ role: "user", content: t.q }, { role: "assistant", content: t.a });
    messages.push({ role: "user", content: `追問：${q}\n（請根據同一張盤回答，說明是看哪幾爻、什麼生剋得出的；白話，300 字以內。）` });
    // 先佔用次數，避免連點重複扣
    const { data: upd } = await admin.from("readings").update({ followups: r.followups + 1 }).eq("id", rid).eq("followups", r.followups).select("id");
    if (!upd || !upd.length) return json({ error: "busy", message: "請稍後再試。" }, 409);
    try {
      const text = await callClaude(model, Math.min(maxTokens, 1000), rules, messages);
      await admin.from("readings").update({ thread: [...thread, { q, a: text }] }).eq("id", rid);
      return json({ text, followups_left: followLimit - r.followups - 1 });
    } catch (e) {
      await admin.from("readings").update({ followups: r.followups }).eq("id", rid);
      return json({ error: "claude", message: "卦師暫時沒有回應，這次追問沒有扣次數。", detail: String(e) }, 502);
    }
  }

  return json({ error: "bad_request" }, 400);
});
