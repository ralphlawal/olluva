// POST /functions/v1/review-partner      (invoked by pg_cron and by triggers)
//
// Keeps the App Review demo partner working (see the migration
// 20261011000400_review_partner.sql for what that is and why it is safe):
//   1. makes sure someone is waiting behind the review code, creating a new
//      demo identity when the last one has been paired with;
//   2. greets and answers whoever is paired with a demo partner;
//   3. deletes demo partners that are finished with.
//
// The code comes from the REVIEW_INVITE_CODE secret. With no secret set, the
// code is retired and nobody new can pair. Deploy with --no-verify-jwt.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { isAuthorisedWorker, json, log, requireEnv, serviceClient } from "../_shared/http.ts";

Deno.serve(async (request) => {
  if (!isAuthorisedWorker(request)) return json({ error: "forbidden" }, 403);

  const admin = serviceClient();
  const code = (Deno.env.get("REVIEW_INVITE_CODE") ?? "").trim();
  let provisioned = false;

  if (code === "") {
    await admin.rpc("review_partner_retire");
  } else {
    const needed = await admin.rpc("review_partner_needed", { p_code: code });
    if (needed.error) {
      log("review_partner_check_failed", { code: needed.error.code ?? null });
    } else if (needed.data === true) {
      // A real anonymous identity, made the way the app makes one. Its session
      // is discarded here, so nothing can ever act as it.
      const visitor = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const created = await visitor.auth.signInAnonymously({ options: { data: { display_name: "Demo Partner" } } });
      const userId = created.data.user?.id;
      if (created.error || !userId) {
        log("review_partner_identity_failed", { status: created.error?.status ?? null });
      } else {
        const result = await admin.rpc("review_partner_provision", { p_user: userId, p_code: code });
        if (result.error) {
          log("review_partner_provision_failed", { code: result.error.code ?? null });
          await admin.auth.admin.deleteUser(userId);
        } else {
          provisioned = true;
        }
      }
    }
  }

  const tick = await admin.rpc("review_partner_tick");
  if (tick.error) log("review_partner_tick_failed", { code: tick.error.code ?? null });

  let removed = 0;
  const expired = await admin.rpc("review_partners_expired");
  for (const userId of (expired.data ?? []) as string[]) {
    const prepared = await admin.rpc("prepare_account_deletion", { p_user: userId });
    if (prepared.error) continue;
    const deleted = await admin.auth.admin.deleteUser(userId);
    if (!deleted.error) removed += 1;
  }

  log("review_partner_run", { provisioned, notes: Number(tick.data ?? 0), removed });
  return json({ ok: true, provisioned, notes: Number(tick.data ?? 0), removed });
});
