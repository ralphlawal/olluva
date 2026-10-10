// POST /functions/v1/widget-snapshot      header: x-widget-token
//
// What the Home Screen widget and the notification extension call to learn
// what to show. Authenticated by a widget token: a narrow, revocable
// credential that can read this one thing and nothing else (see the
// widget_tokens migration). Deploy with --no-verify-jwt.
//
// Images are returned as signed URLs that expire in two minutes, long enough
// for the caller to download them once.
import { json, log, serviceClient } from "../_shared/http.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const token = request.headers.get("x-widget-token") ?? "";
  if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "forbidden" }, 403);

  const admin = serviceClient();
  const { data, error } = await admin.rpc("widget_snapshot", { p_token: token });
  if (error) {
    log("widget_snapshot_failed", { code: error.code ?? null });
    return json({ error: "internal" }, 500);
  }
  // Unknown or revoked: tell the caller to stop showing what it has.
  if (data === null) return json({ error: "forbidden" }, 403);

  const note = data.note as { photo_path?: string | null; drawing_path?: string | null } | null;
  const sign = async (path: string | null | undefined): Promise<string | null> => {
    if (!path) return null;
    const signed = await admin.storage.from("couple-media").createSignedUrl(path, 120);
    return signed.data?.signedUrl ?? null;
  };
  const [photoUrl, drawingUrl] = await Promise.all([sign(note?.photo_path), sign(note?.drawing_path)]);

  return json({ ...data, photo_url: photoUrl, drawing_url: drawingUrl });
});
