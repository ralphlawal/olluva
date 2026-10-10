// Starts a throwaway Postgres, applies the Supabase shim and every migration,
// and exposes helpers for running SQL as a particular API role and user —
// the same way PostgREST does it (SET ROLE + request.jwt.claims).

import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '..', '..', 'migrations');

export async function startDatabase() {
  const dataDir = mkdtempSync(join(tmpdir(), 'couple-notes-pg-'));
  const port = 54000 + Math.floor(Math.random() * 1000);
  const server = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: 'postgres',
    password: 'postgres',
    port,
    persistent: false,
    onLog: () => {},
    onError: () => {},
  });
  await server.initialise();
  await server.start();

  const pool = new pg.Pool({
    host: 'localhost', port, user: 'postgres', password: 'postgres', database: 'postgres', max: 12,
  });

  await pool.query(readFileSync(join(here, 'supabase_shim.sql'), 'utf8'));
  for (const file of readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort()) {
    try {
      await pool.query(readFileSync(join(migrationsDir, file), 'utf8'));
    } catch (error) {
      error.message = `${file}: ${error.message}`;
      throw error;
    }
  }

  // Runs `fn` inside one transaction as the given role. Commits on success.
  async function withRole(role, userId, fn) {
    const client = await pool.connect();
    try {
      await client.query('begin');
      const claims = userId ? { sub: userId, role } : { role };
      await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
      await client.query(`set local role ${role}`);
      const result = await fn((sql, params) => client.query(sql, params));
      await client.query('commit');
      return result;
    } catch (error) {
      await client.query('rollback').catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  const db = {
    pool,
    /** Superuser: for arranging state and asserting on it, never for the act under test. */
    admin: (sql, params) => pool.query(sql, params),
    as: (userId, fn) => withRole('authenticated', userId, fn),
    asAnon: (fn) => withRole('anon', null, fn),
    asService: (fn) => withRole('service_role', null, fn),

    /** One statement as a user; returns rows. */
    async query(userId, sql, params) {
      return (await db.as(userId, (q) => q(sql, params))).rows;
    },

    /** One RPC-style call returning a single value. */
    async call(userId, sql, params) {
      const rows = await db.query(userId, sql, params);
      return rows[0] ? Object.values(rows[0])[0] : undefined;
    },

    /** Asserts that a statement run as `userId` is refused, with a matching message. */
    async rejects(userId, sql, params, pattern) {
      await assert.rejects(() => db.query(userId, sql, params), (error) => {
        assert.match(error.message, pattern, `unexpected error: ${error.message}`);
        return true;
      });
    },

    /** A person who has started and chosen a name: an anonymous identity, as the app creates. */
    async createUser(name) {
      const { rows } = await pool.query(
        `insert into auth.users (is_anonymous, raw_user_meta_data) values (true, $1) returning id`,
        [{ display_name: name }],
      );
      return rows[0].id;
    },

    /** A brand-new anonymous identity, exactly as "Get started" leaves it: no name yet. */
    async createAnonymous() {
      const { rows } = await pool.query(`insert into auth.users (is_anonymous) values (true) returning id`);
      return rows[0].id;
    },

    /** Two users paired through the real invitation flow. */
    async createCouple(nameA = 'Ada', nameB = 'Ben') {
      const a = await db.createUser(nameA);
      const b = await db.createUser(nameB);
      const coupleId = await db.call(a, 'select public.create_couple_space()');
      const invite = await db.call(a, 'select public.create_invitation()');
      const accepted = await db.call(b, 'select public.accept_invitation($1)', [invite.code]);
      assert.equal(accepted.ok, true);
      return { a, b, coupleId };
    },

    async makePremium(userId, { status = 'active', expires = "now() + interval '30 days'" } = {}) {
      const id = `test-${Math.random().toString(36).slice(2)}`;
      await pool.query(
        `insert into public.subscriptions
           (original_transaction_id, user_id, product_id, status, expires_at, environment)
         values ($1, $2, 'premium.monthly', $3, ${expires}, 'Xcode')`,
        [id, userId, status],
      );
      return id;
    },

    async stop() {
      await pool.end();
      await server.stop();
      rmSync(dataDir, { recursive: true, force: true });
    },
  };
  return db;
}

export function mediaPath(coupleId, ext = 'jpg') {
  return `couples/${coupleId}/${crypto.randomUUID()}.${ext}`;
}
