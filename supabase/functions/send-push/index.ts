// POST /functions/v1/send-push      (invoked every minute by pg_cron)
// Drains the notification outbox. Deploy with --no-verify-jwt; access is
// controlled by the CRON_SECRET header instead.
import { isAuthorisedWorker, json, log, serviceClient } from "../_shared/http.ts";
import { lastWidgetPushRejection, sendBackgroundPush, sendPush, sendWidgetPush } from "../_shared/apns.ts";
import { type ClaimedNotification, notificationText } from "../_shared/messages.ts";

Deno.serve(async (request) => {
  if (!isAuthorisedWorker(request)) return json({ error: "forbidden" }, 403);

  const admin = serviceClient();
  // Claiming marks rows as in progress in the same statement that selects
  // them, so overlapping runs never send the same notification twice.
  const { data, error } = await admin.rpc("claim_notifications", { p_limit: 100 });
  if (error) {
    log("claim_failed", { code: error.code ?? null });
    return json({ error: "claim_failed" }, 500);
  }

  let sent = 0;
  let failed = 0;
  let widgetPushes = 0;
  for (const item of (data ?? []) as ClaimedNotification[]) {
    // Anything that changes what the widget shows also goes straight to the
    // widget (iOS 26+). This does not depend on the app, on notification
    // permission, or on the alert below being delivered.
    if (["new_note", "surprise", "sync"].includes(item.category)) {
      const deadWidgetTokens: string[] = [];
      for (const widget of item.widget_push ?? []) {
        try {
          const result = await sendWidgetPush(widget.token, widget.environment);
          if (result === "sent") widgetPushes += 1;
          else if (result === "invalid_token") deadWidgetTokens.push(widget.token);
        } catch { /* best effort; the widget also refreshes on its own schedule */ }
      }
      if (deadWidgetTokens.length > 0) {
        await admin.rpc("clear_widget_push_tokens", { p_push_tokens: deadWidgetTokens });
      }
    }

    // A sync entry shows nothing: it only asks the app to refresh itself.
    const isSync = item.category === "sync";
    const text = isSync ? { title: "", body: "", data: {} } : notificationText(item);
    if (!text || item.tokens.length === 0) {
      await admin.rpc("complete_notification", { p_id: item.id, p_status: "skipped", p_invalid_tokens: [] });
      continue;
    }

    const invalid: string[] = [];
    let delivered = false;
    let retryable = false;
    for (const device of item.tokens) {
      try {
        const result = isSync
          ? await sendBackgroundPush(device.token, device.environment, {})
          : await sendPush(device.token, device.environment, {
            title: text.title,
            body: text.body,
            category: item.category,
            data: { ...text.data, category: item.category },
          });
        if (result === "sent") delivered = true;
        else if (result === "invalid_token") invalid.push(device.token);
        else retryable = true;
      } catch {
        retryable = true;
      }
    }

    // Back to pending if nothing got through but a retry might; the claim
    // function stops offering a row after five attempts.
    const status = delivered ? "sent" : retryable ? "pending" : "failed";
    await admin.rpc("complete_notification", { p_id: item.id, p_status: status, p_invalid_tokens: invalid });
    if (delivered) sent += 1;
    else failed += 1;
  }

  log("push_run", { claimed: data?.length ?? 0, sent, failed, widgetPushes });
  return json({ ok: true, sent, failed, widgetPushes, widgetRejection: lastWidgetPushRejection });
});
