// POST /functions/v1/verify-purchase   { "jws": "<StoreKit 2 signed transaction>" }
//
// The only client-reachable path that can create an entitlement. It trusts
// nothing in the request except Apple's signature:
//   * the caller is identified by their access token;
//   * the transaction must verify against Apple's certificate chain;
//   * it must be for this app and one of our products;
//   * if it carries an appAccountToken, that must be the caller.
import { authenticatedUserId, json, log, requireEnv, serviceClient } from "../_shared/http.ts";
import {
  type AppleTransaction,
  assertExpectedTransaction,
  JwsVerificationError,
  subscriptionRecord,
  verifyAppleJws,
} from "../_shared/jws.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const userId = await authenticatedUserId(request);
  if (!userId) return json({ error: "not_authenticated" }, 401);

  let jws: unknown;
  try {
    jws = (await request.json()).jws;
  } catch {
    return json({ error: "invalid_transaction" }, 400);
  }
  if (typeof jws !== "string" || jws.length > 20_000) return json({ error: "invalid_transaction" }, 400);

  let transaction: AppleTransaction;
  try {
    transaction = verifyAppleJws<AppleTransaction>(jws);
    assertExpectedTransaction(transaction, {
      bundleId: requireEnv("APPLE_BUNDLE_ID"),
      productIds: requireEnv("APPLE_PRODUCT_IDS").split(",").map((id) => id.trim()),
      // Sandbox purchases are accepted only where explicitly enabled
      // (development and TestFlight projects), never by default.
      allowTestEnvironments: Deno.env.get("APPLE_ALLOW_SANDBOX") === "true",
    });
  } catch (error) {
    log("purchase_rejected", { reason: error instanceof JwsVerificationError ? error.reason : "unknown" });
    return json({ error: "verification_failed" }, 400);
  }

  const record = subscriptionRecord(transaction, null, new Date());
  // A purchase bound to a different account cannot be claimed by this one.
  if (record.userId !== null && record.userId !== userId) {
    log("purchase_rejected", { reason: "account_mismatch" });
    return json({ error: "owned_by_other_account" }, 409);
  }

  const { data, error } = await serviceClient().rpc("record_subscription", {
    p_original_transaction_id: record.originalTransactionId,
    p_user: userId,
    p_product_id: record.productId,
    p_status: record.status,
    p_expires_at: record.expiresAt,
    p_auto_renew: record.autoRenew,
    p_environment: record.environment,
    p_last_transaction_id: record.lastTransactionId,
  });
  if (error) {
    log("purchase_record_failed", { code: error.code ?? null });
    return json({ error: "record_failed" }, 500);
  }
  if (data === "owned_by_other_account") return json({ error: "owned_by_other_account" }, 409);

  log("purchase_recorded", { status: record.status, environment: record.environment });
  return json({ ok: true, status: record.status });
});
