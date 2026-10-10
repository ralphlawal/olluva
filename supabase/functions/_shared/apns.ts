// Apple Push Notification service, over HTTP/2 with token authentication.
// The signing key (.p8) is a server secret and never leaves this function.
import { requireEnv } from "./http.ts";

let cachedToken: { value: string; issuedAt: number } | null = null;

function base64Url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A provider token. APNs wants it reused for 20–60 minutes, not minted per push. */
async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 40 * 60) return cachedToken.value;

  const pem = requireEnv("APNS_PRIVATE_KEY").replace(/\\n/g, "\n");
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")),
    (character) => character.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);

  const header = base64Url(JSON.stringify({ alg: "ES256", kid: requireEnv("APNS_KEY_ID") }));
  const claims = base64Url(JSON.stringify({ iss: requireEnv("APNS_TEAM_ID"), iat: now }));
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  cachedToken = { value: `${header}.${claims}.${base64Url(signature)}`, issuedAt: now };
  return cachedToken.value;
}

export interface PushMessage {
  title: string;
  body: string;
  category: string;
  /** Identifiers only. Used by the app to open the right screen. */
  data: Record<string, string>;
  /** Groups notifications from one space together. */
  threadId?: string;
}

export type PushResult = "sent" | "invalid_token" | "failed";

export async function sendPush(
  token: string,
  environment: "sandbox" | "production",
  message: PushMessage,
): Promise<PushResult> {
  const host = environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": requireEnv("APPLE_BUNDLE_ID"),
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 24 * 3600),
    },
    body: JSON.stringify({
      aps: {
        alert: { title: message.title, body: message.body },
        sound: "default",
        "thread-id": message.threadId,
        // Wakes the app briefly so it can fetch the note and refresh the
        // widget. iOS may throttle or skip this; the alert is still shown.
        "content-available": 1,
      },
      category: message.category,
      ...message.data,
    }),
  });

  if (response.ok) return "sent";
  const reason = await response.json().then((body) => body?.reason as string | undefined).catch(() => undefined);
  if (response.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") {
    return "invalid_token";
  }
  return "failed";
}
