// POST /functions/v1/purge-storage      (invoked by pg_cron)
// Deletes media that no note, memory or pending surprise refers to any more.
// Storage objects must be removed through the Storage API, so the database
// queues paths and this function removes them. Deploy with --no-verify-jwt.
import { isAuthorisedWorker, json, log, serviceClient } from "../_shared/http.ts";

Deno.serve(async (request) => {
  if (!isAuthorisedWorker(request)) return json({ error: "forbidden" }, 403);

  const admin = serviceClient();
  const { data, error } = await admin.rpc("claim_storage_purges", { p_limit: 200 });
  if (error) {
    log("purge_claim_failed", { code: error.code ?? null });
    return json({ error: "claim_failed" }, 500);
  }

  const byBucket = new Map<string, string[]>();
  for (const row of (data ?? []) as { bucket_id: string; path: string }[]) {
    byBucket.set(row.bucket_id, [...(byBucket.get(row.bucket_id) ?? []), row.path]);
  }

  let removed = 0;
  for (const [bucket, paths] of byBucket) {
    const result = await admin.storage.from(bucket).remove(paths);
    if (result.error) {
      // Left in the queue; the next run tries again.
      log("purge_failed", { bucket });
      continue;
    }
    await admin.rpc("complete_storage_purges", { p_bucket_id: bucket, p_paths: paths });
    removed += paths.length;
  }

  log("purge_run", { removed });
  return json({ ok: true, removed });
});
