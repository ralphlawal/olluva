// Small helpers shared by every function.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing_env:${name}`);
  return value;
}

/** A client with full database rights. Never created from request input. */
export function serviceClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Identifies the caller from their own access token, validated by Supabase
 * Auth. Returns null for a missing, malformed or expired token.
 */
export async function authenticatedUserId(request: Request): Promise<string | null> {
  const header = request.headers.get("authorization") ?? "";
  if (!header.toLowerCase().startsWith("bearer ")) return null;
  const token = header.slice("bearer ".length).trim();
  if (!token) return null;
  const client = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // The token has to be passed explicitly: with no stored session, getUser()
  // without an argument reports "no session" whatever header was sent. The
  // auth server checks the signature and that the user still exists.
  const { data, error } = await client.auth.getUser(token);
  return error || !data.user ? null : data.user.id;
}

/**
 * Worker functions are invoked by pg_cron, not by users. They require a shared
 * secret, compared in constant time.
 */
export function isAuthorisedWorker(request: Request): boolean {
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  const given = request.headers.get("x-cron-secret") ?? "";
  if (expected.length < 24 || given.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) {
    difference |= expected.charCodeAt(index) ^ given.charCodeAt(index);
  }
  return difference === 0;
}

/** Logs an event name and safe fields only. Never pass user content here. */
export function log(event: string, fields: Record<string, string | number | boolean | null> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}
