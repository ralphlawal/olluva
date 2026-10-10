// POST /functions/v1/delete-account
// Deletes the calling user's account and the data they own.
//
// The user is identified only by their own access token. There is no
// parameter naming an account, so one person cannot delete another.
import { authenticatedUserId, json, log, serviceClient } from "../_shared/http.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const userId = await authenticatedUserId(request);
  if (!userId) return json({ error: "not_authenticated" }, 401);

  const admin = serviceClient();

  // 1. Remove authored content, end the shared space, queue media for purge.
  const prepared = await admin.rpc("prepare_account_deletion", { p_user: userId });
  if (prepared.error) {
    log("delete_account_prepare_failed", { code: prepared.error.code ?? null });
    return json({ error: "deletion_failed" }, 500);
  }

  // 2. Remove the auth user. Foreign keys cascade from auth.users to the
  //    profile and everything keyed to it (tokens, preferences, subscriptions).
  const removed = await admin.auth.admin.deleteUser(userId);
  if (removed.error) {
    log("delete_account_auth_failed", { status: removed.error.status ?? null });
    return json({ error: "deletion_failed" }, 500);
  }

  log("account_deleted");
  return json({ ok: true });
});
