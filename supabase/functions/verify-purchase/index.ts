// POST /functions/v1/verify-purchase   { "jws": "<StoreKit 2 signed transaction>" }
//
// The only client-reachable path that can create an entitlement. It trusts
// nothing in the request except Apple's signature:
//   * the caller is identified by their access token;
//   * the transaction must verify against Apple's certificate chain;
//   * it must be for this app and one of our products.
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
    transaction = await verifyAppleJws<AppleTransaction>(jws);
    assertExpectedTransaction(transaction, {
      bundleId: requireEnv("APPLE_BUNDLE_ID"),
      productIds: requireEnv("APPLE_PRODUCT_IDS").split(",").map((id) => id.trim()),
      // Sandbox purchases are accepted only where explicitly enabled
      // (development and TestFlight projects), never by default.
      allowTestEnvironments: Deno.env.get("APPLE_ALLOW_SANDBOX") === "true",
    });
  } catch (error) {
    // An unexpected error here is a fault in this function, not in the
    // transaction. Its text comes from the runtime and holds no user data.
    const detail = error instanceof JwsVerificationError ? null : String(error).slice(0, 160);
    log("purchase_rejected", { reason: error instanceof JwsVerificationError ? error.reason : "unknown", detail });
    return json({ error: "verification_failed" }, 400);
  }

  const record = subscriptionRecord(transaction, null, new Date());
  // The caller is holding a transaction Apple signed, so the subscription is
  // theirs, whichever identity first presented it: identities are replaced on
  // reinstall, an Apple ID's purchase is not. Claiming it moves it; it never
  // covers two identities at once.
  const { data, error } = await serviceClient().rpc("claim_subscription", {
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
  log("purchase_recorded", { status: record.status, environment: record.environment, outcome: String(data) });
  return json({ ok: true, status: record.status });
});
