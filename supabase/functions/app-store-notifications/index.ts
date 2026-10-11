// POST /functions/v1/app-store-notifications
// App Store Server Notifications V2 endpoint. Configure this URL in App Store
// Connect. Deploy with --no-verify-jwt: Apple does not send a Supabase token;
// authenticity comes from the notification's own signature.
//
// Keeps subscriptions current when nobody has the app open: renewals,
// expirations, billing problems, refunds and revocations.
import { json, log, requireEnv, serviceClient } from "../_shared/http.ts";
import {
  type AppleRenewalInfo,
  type AppleTransaction,
  assertExpectedTransaction,
  JwsVerificationError,
  subscriptionRecord,
  verifyAppleJws,
} from "../_shared/jws.ts";

interface NotificationPayload {
  notificationType: string;
  subtype?: string;
  data?: { signedTransactionInfo?: string; signedRenewalInfo?: string; bundleId?: string };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let signedPayload: unknown;
  try {
    signedPayload = (await request.json()).signedPayload;
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  if (typeof signedPayload !== "string") return json({ error: "invalid_body" }, 400);

  try {
    const notification = await verifyAppleJws<NotificationPayload>(signedPayload);
    const signedTransaction = notification.data?.signedTransactionInfo;
    // Some notification types (e.g. TEST) carry no transaction. Acknowledge them.
    if (!signedTransaction) return json({ ok: true });

    // The inner documents are signed separately and are verified separately.
    const transaction = await verifyAppleJws<AppleTransaction>(signedTransaction);
    const renewal = notification.data?.signedRenewalInfo
      ? await verifyAppleJws<AppleRenewalInfo>(notification.data.signedRenewalInfo)
      : null;

    assertExpectedTransaction(transaction, {
      bundleId: requireEnv("APPLE_BUNDLE_ID"),
      productIds: requireEnv("APPLE_PRODUCT_IDS").split(",").map((id) => id.trim()),
      allowTestEnvironments: Deno.env.get("APPLE_ALLOW_SANDBOX") === "true",
    });

    const record = subscriptionRecord(transaction, renewal, new Date());
    const { error } = await serviceClient().rpc("record_subscription", {
      p_original_transaction_id: record.originalTransactionId,
      p_user: record.userId,
      p_product_id: record.productId,
      p_status: record.status,
      p_expires_at: record.expiresAt,
      p_auto_renew: record.autoRenew,
      p_environment: record.environment,
      p_last_transaction_id: record.lastTransactionId,
    });
    if (error) {
      // A 5xx makes Apple retry later, which is what we want here.
      log("notification_record_failed", { code: error.code ?? null });
      return json({ error: "record_failed" }, 500);
    }
    log("notification_processed", { type: notification.notificationType, status: record.status });
    return json({ ok: true });
  } catch (error) {
    if (error instanceof JwsVerificationError) {
      log("notification_rejected", { reason: error.reason });
      return json({ error: "verification_failed" }, 400);
    }
    log("notification_failed");
    return json({ error: "internal" }, 500);
  }
});
