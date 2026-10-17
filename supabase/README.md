# 六爻卦館 會員後台

- `schema.sql`：資料庫結構（Supabase → SQL Editor 貼上執行，可重複執行）
- `functions/guashi/index.ts`：卦師解卦伺服器（Supabase → Edge Functions 新增名為 `guashi` 的函式，貼上內容部署；Secrets 加 `ANTHROPIC_API_KEY`）
- 網站：`guaguan.html`（會員端）、`guaguan-admin.html`（管理端）
- 價格、卦數、收款資訊、規則書、模型都在管理頁改，不用改程式
