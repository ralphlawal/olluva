import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { mediaPath, startDatabase } from './support/db.js';

let db;
before(async () => { db = await startDatabase(); });
after(async () => { await db?.stop(); });

const TOKEN = (seed) => seed.repeat(64).slice(0, 64);

describe('entitlements', () => {
  test('clients cannot create, alter or extend a subscription', async () => {
    const { a } = await db.createCouple();
    await db.rejects(
      a, `insert into public.subscriptions (original_transaction_id, user_id, product_id, status, environment) values ('x', $1, 'p', 'active', 'Production')`,
      [a], /permission denied/,
    );
    const real = await db.makePremium(a, { status: 'expired', expires: `now() - interval '1 day'` });
    await db.rejects(a, `update public.subscriptions set status = 'active', expires_at = now() + interval '10 years'`, [], /permission denied/);
    await db.rejects(a, 'delete from public.subscriptions', [], /permission denied/);
    await db.rejects(
      a, `select public.record_subscription($1, $2, 'p', 'active', now() + interval '1 year', true, 'Production', 't')`,
      [real, a], /permission denied/,
    );
    assert.equal((await db.call(a, 'select public.get_entitlement()')).is_premium, false);
  });

  test('one partner\'s subscription makes the couple premium, and each sees why', async () => {
    const { a, b } = await db.createCouple();
    assert.equal((await db.call(a, 'select public.get_entitlement()')).is_premium, false);
    await db.makePremium(a);
    const mine = await db.call(a, 'select public.get_entitlement()');
    const theirs = await db.call(b, 'select public.get_entitlement()');
    assert.deepEqual([mine.is_premium, mine.source], [true, 'self']);
    assert.deepEqual([theirs.is_premium, theirs.source, theirs.expires_at], [true, 'partner', null]);
    assert.equal(theirs.memories_limit, 2000);
    // The partner cannot see the purchase record itself.
    assert.deepEqual(await db.query(b, 'select * from public.subscriptions'), []);
  });

  test('premium follows the purchaser after unlinking', async () => {
    const { a, b } = await db.createCouple();
    await db.makePremium(a);
    await db.query(a, 'select public.leave_couple()');
    assert.equal((await db.call(a, 'select public.get_entitlement()')).is_premium, true);
    assert.equal((await db.call(b, 'select public.get_entitlement()')).is_premium, false);
  });

  test('expired, revoked and billing-retry subscriptions grant nothing; grace does', async () => {
    const cases = [
      [{ status: 'expired', expires: `now() - interval '1 day'` }, false],
      [{ status: 'active', expires: `now() - interval '1 minute'` }, false],
      [{ status: 'revoked', expires: `now() + interval '20 days'` }, false],
      [{ status: 'billing_retry', expires: `now() + interval '20 days'` }, false],
      [{ status: 'grace', expires: `now() + interval '3 days'` }, true],
    ];
    for (const [subscription, expected] of cases) {
      const user = await db.createUser('Ada');
      await db.makePremium(user, subscription);
      assert.equal((await db.call(user, 'select public.get_entitlement()')).is_premium, expected, JSON.stringify(subscription));
    }
  });

  test('the trusted recorder binds a purchase to one account and applies refunds', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const record = (user, status, expires) => db.asService((q) => q(
      `select public.record_subscription('otid-1', $1, 'premium.yearly', $2, ${expires}, true, 'Sandbox', 'tx') as r`, [user, status],
    )).then((r) => r.rows[0].r);

    assert.equal(await record(a, 'active', `now() + interval '1 year'`), 'recorded');
    // A server notification naming someone else never changes who owns it.
    assert.equal(await record(b, 'active', `now() + interval '1 year'`), 'updated');
    assert.equal((await db.call(a, 'select public.get_entitlement()')).source, 'self');
    assert.equal((await db.call(b, 'select public.get_entitlement()')).source, 'partner');

    await db.query(a, `select public.set_couple_theme('dusk', '#AA5577')`);
    // Server notification with no user attached (a refund) updates the existing row.
    assert.equal(await record(null, 'revoked', 'now()'), 'updated');
    assert.equal((await db.call(a, 'select public.get_entitlement()')).is_premium, false);
    await db.rejects(a, `select public.set_couple_theme('ink')`, [], /premium_required/);
    await db.query(a, `select public.set_couple_theme('plum')`);
    assert.equal((await db.query(b, 'select theme_id from public.couple_spaces where id = $1', [coupleId]))[0].theme_id, 'plum');
  });

  test('premium themes and accents require premium; unknown themes are refused', async () => {
    const { a } = await db.createCouple();
    await db.rejects(a, `select public.set_couple_theme('linen')`, [], /premium_required/);
    await db.rejects(a, `select public.set_couple_theme('paper', '#112233')`, [], /premium_required/);
    await db.rejects(a, `select public.set_couple_theme('nope')`, [], /unknown_theme/);
    await db.makePremium(a);
    await db.rejects(a, `select public.set_couple_theme('linen', 'red')`, [], /invalid_accent/);
    await db.query(a, `select public.set_couple_theme('linen', '#112233')`);
  });
});

describe('notifications', () => {
  test('a new note queues exactly one notification, for the partner, without the note text', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'a very private sentence')`, [coupleId, a]);
    const { rows } = await db.admin(`select user_id, category, payload::text as payload from public.notification_outbox where category = 'new_note' and user_id = any($1)`, [[a, b]]);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].user_id, b);
    assert.ok(!rows[0].payload.includes('private sentence'));
  });

  test('deleting or editing a note queues a silent refresh for the partner, whatever their preferences', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(b, 'update public.notification_preferences set new_notes = false');
    const [note] = await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'regret this') returning id`, [coupleId, a]);
    const sync = async () => (await db.admin(`select user_id, payload::text as payload from public.notification_outbox where category = 'sync' and user_id = any($1) order by id`, [[a, b]])).rows;

    // Being read is not a change to what is shown: the author's phone is not woken.
    await db.query(b, 'select public.mark_note_seen($1)', [note.id]);
    assert.deepEqual(await sync(), []);

    await db.query(a, 'select public.update_note($1, 1, $2, $3, null, null)', [note.id, 'better words', {}]);
    await db.query(a, 'select public.delete_note($1)', [note.id]);
    const rows = await sync();
    assert.equal(rows.length, 2, 'one for the edit, one for the delete');
    assert.ok(rows.every((r) => r.user_id === b), 'only the partner, never the author');
    assert.ok(rows.every((r) => !r.payload.includes('regret') && !r.payload.includes('better')), 'no content in the queue');
  });

  test('previews are off by default and included only when the recipient opts in', async () => {
    const { a, b, coupleId } = await db.createCouple('Ada', 'Ben');
    await db.query(b, 'select public.register_device_token($1, $2)', [TOKEN('ab'), 'sandbox']);
    const send = () => db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'lunch at one?')`, [coupleId, a]);
    const claim = async () => (await db.asService((q) => q('select * from public.claim_notifications(50)'))).rows.filter((r) => r.user_id === b);

    await send();
    const [hidden] = await claim();
    assert.deepEqual([hidden.sender_name, hidden.preview, hidden.tokens.length], ['Ada', null, 1]);

    await db.query(b, 'update public.notification_preferences set show_previews = true');
    await send();
    const [shown] = await claim();
    assert.equal(shown.preview, 'lunch at one?');
    // Claimed rows are not handed out twice.
    assert.deepEqual(await claim(), []);
  });

  test('a disabled category queues nothing', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(b, 'update public.notification_preferences set new_notes = false');
    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'shh')`, [coupleId, a]);
    const { rows } = await db.admin(`select 1 from public.notification_outbox where user_id = $1 and category = 'new_note'`, [b]);
    assert.equal(rows.length, 0);
  });

  test('preferences and tokens are private to their owner', async () => {
    const { a, b } = await db.createCouple();
    await db.query(a, 'select public.register_device_token($1, $2)', [TOKEN('cd'), 'production']);
    await db.rejects(b, 'select * from public.device_tokens', [], /permission denied/);
    assert.equal((await db.query(b, 'select user_id from public.notification_preferences')).length, 1);
    const changed = await db.as(b, (q) => q('update public.notification_preferences set show_previews = true where user_id = $1', [a]));
    assert.equal(changed.rowCount, 0);
    await db.rejects(a, `select public.register_device_token('not-a-token', 'sandbox')`, [], /device_tokens_token_check/);
  });

  test('a device token moves with the signed-in account and stops on sign-out', async () => {
    const { a, b } = await db.createCouple();
    const token = TOKEN('ef');
    await db.query(a, 'select public.register_device_token($1, $2)', [token, 'sandbox']);
    await db.query(b, 'select public.register_device_token($1, $2)', [token, 'sandbox']);
    const owner = async () => (await db.admin('select user_id from public.device_tokens where token = $1', [token])).rows.map((r) => r.user_id);
    assert.deepEqual(await owner(), [b]);
    await db.query(a, 'select public.unregister_device_token($1)', [token]); // not a's any more: no effect
    assert.deepEqual(await owner(), [b]);
    await db.query(b, 'select public.unregister_device_token($1)', [token]);
    assert.deepEqual(await owner(), []);
  });

  test('a device token is only ever registered under one push environment', async () => {
    const { a } = await db.createCouple();
    const token = TOKEN('9a');
    const environments = async () => (await db.admin('select environment from public.device_tokens where token = $1', [token])).rows.map((r) => r.environment);
    await db.query(a, 'select public.register_device_token($1, $2)', [token, 'production']);
    await db.query(a, 'select public.register_device_token($1, $2)', [token, 'sandbox']);
    assert.deepEqual(await environments(), ['sandbox']);
    await db.query(a, 'select public.register_device_token($1, $2)', [token, 'production']);
    assert.deepEqual(await environments(), ['production']);
  });

  test('a purchase follows the device that holds it, and covers one identity at a time', async () => {
    const first = await db.createCouple('Ada', 'Ben');
    const second = await db.createCouple('Ada again', 'Cy');
    const claim = (user) => db.asService((q) => q(
      `select public.claim_subscription('otid-claim', $1, 'premium.yearly', 'active', now() + interval '1 year', true, 'Sandbox', 'tx') as r`, [user],
    )).then((r) => r.rows[0].r);
    const premium = async (user) => (await db.call(user, 'select public.get_entitlement()')).is_premium;

    assert.equal(await claim(first.a), 'recorded');
    assert.equal(await premium(first.b), true);

    // The same person starts over with a new identity and restores.
    assert.equal(await claim(second.a), 'transferred');
    assert.equal(await premium(second.a), true);
    assert.equal(await premium(second.b), true);
    assert.equal(await premium(first.a), false);
    assert.equal(await premium(first.b), false);
    assert.equal(await claim(second.a), 'updated');
    assert.equal((await db.admin(`select count(*)::int as n from public.subscriptions where original_transaction_id = 'otid-claim'`)).rows[0].n, 1);

    // A notification for an identity that no longer exists opens nothing.
    const gone = '00000000-0000-4000-8000-000000000001';
    const notify = await db.asService((q) => q(
      `select public.record_subscription('otid-orphan', $1, 'premium.yearly', 'active', now() + interval '1 year', true, 'Sandbox', 'tx') as r`, [gone],
    ));
    assert.equal(notify.rows[0].r, 'unknown_owner');

    // Nobody but trusted server code can claim.
    await db.rejects(first.a, `select public.claim_subscription('otid-x', $1, 'p', 'active', now(), true, 'Sandbox', 'tx')`, [first.a], /permission denied/);
  });

  test('a new profile picture or name reaches the partner, and only the partner', async () => {
    const { a, b } = await db.createCouple();
    const outsider = await db.createUser('Zed');
    const version = async () => (await db.admin('select avatar_version from public.profiles where id = $1', [a])).rows[0].avatar_version;
    const syncs = async (user) => (await db.admin(
      `select count(*)::int as n from public.notification_outbox where user_id = $1 and category = 'sync' and dedupe_key like 'sync:profile:%'`, [user],
    )).rows[0].n;
    const path = `${a}/avatar.jpg`;

    await db.query(a, 'update public.profiles set avatar_path = $1 where id = $2', [path, a]);
    assert.equal(await version(), 1);
    // A replacement picture is stored at the same path: it must still count.
    await db.query(a, 'update public.profiles set avatar_path = $1 where id = $2', [path, a]);
    assert.equal(await version(), 2);
    assert.equal(await syncs(b), 2);
    assert.equal(await syncs(a), 0);
    assert.equal(await syncs(outsider), 0);

    await db.query(a, `update public.profiles set display_name = 'Ada L' where id = $1`, [a]);
    assert.equal(await syncs(b), 3);
    // The time zone is nobody else's business and wakes nobody.
    await db.query(a, `update public.profiles set time_zone = 'Europe/Dublin' where id = $1`, [a]);
    assert.equal(await syncs(b), 3);

    // The counter belongs to the server.
    await db.rejects(a, 'update public.profiles set avatar_version = 99 where id = $1', [a], /permission denied/);
    // The partner can read it; a stranger cannot read the profile at all.
    assert.equal((await db.query(b, 'select avatar_version from public.profiles where id = $1', [a]))[0].avatar_version, 2);
    assert.equal((await db.query(outsider, 'select avatar_version from public.profiles where id = $1', [a])).length, 0);
  });

  test('pairing and unlinking notify the other person only', async () => {

    const { a, b, coupleId } = await db.createCouple();
    const outbox = async (user) => (await db.admin('select category, payload from public.notification_outbox where user_id = $1 order by id', [user])).rows;
    assert.deepEqual((await outbox(a)).map((r) => [r.category, r.payload.event]), [['pairing', 'accepted']]);
    assert.deepEqual(await outbox(b), []);
    await db.query(a, 'select public.leave_couple()');
    assert.deepEqual((await outbox(b)).map((r) => [r.category, r.payload.event]), [['account', 'space_ended']]);
    assert.equal((await outbox(a)).length, 1);
    assert.ok(coupleId);
  });

  test('dead tokens reported by APNs are removed', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(b, 'select public.register_device_token($1, $2)', [TOKEN('12'), 'sandbox']);
    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'hi')`, [coupleId, a]);
    const claimed = (await db.asService((q) => q('select * from public.claim_notifications(50)'))).rows.find((r) => r.user_id === b);
    await db.asService((q) => q('select public.complete_notification($1, $2, $3)', [claimed.id, 'failed', [TOKEN('12')]]));
    assert.equal((await db.admin('select 1 from public.device_tokens where user_id = $1', [b])).rows.length, 0);
  });
});

describe('export and deletion', () => {
  async function populated() {
    const couple = await db.createCouple('Ada', 'Ben');
    const { a, b, coupleId } = couple;
    const photo = mediaPath(coupleId);
    await db.query(a, `insert into public.notes (couple_id, author_id, body, photo_path) values ($1, $2, 'from ada', $3)`, [coupleId, a, photo]);
    await db.query(b, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'from ben')`, [coupleId, b]);
    await db.query(a, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'moment', 'Ada moment')`, [coupleId, a]);
    await db.query(b, `insert into public.important_dates (couple_id, created_by, title, starts_on) values ($1, $2, 'Ben date', '2021-01-01')`, [coupleId, b]);
    return { ...couple, photo };
  }

  test('an export contains what the person authored and nothing their partner wrote', async () => {
    const { a } = await populated();
    const data = await db.call(a, 'select public.export_my_data()');
    assert.equal(data.profile.display_name, 'Ada');
    assert.deepEqual(data.notes.map((n) => n.body), ['from ada']);
    assert.deepEqual(data.memories.map((m) => m.title), ['Ada moment']);
    assert.deepEqual(data.important_dates, []);
    assert.ok(!JSON.stringify(data).includes('from ben'));
  });

  test('an export still works after unlinking, when the space itself is no longer readable', async () => {
    const { a } = await populated();
    await db.query(a, 'select public.leave_couple()');
    assert.deepEqual(await db.query(a, 'select id from public.notes'), []);
    const data = await db.call(a, 'select public.export_my_data()');
    assert.deepEqual(data.notes.map((n) => n.body), ['from ada']);
  });

  test('deleting an account removes that person\'s data, frees their partner, and keeps the partner\'s account', async () => {
    const { a, b, coupleId, photo } = await populated();
    await db.makePremium(a);
    await db.query(a, 'select public.register_device_token($1, $2)', [TOKEN('9a'), 'sandbox']);

    await db.rejects(a, 'select public.prepare_account_deletion($1)', [a], /permission denied/);
    await db.asService((q) => q('select public.prepare_account_deletion($1)', [a]));
    await db.admin('delete from auth.users where id = $1', [a]);

    for (const [table, column] of [
      ['profiles', 'id'], ['notes', 'author_id'], ['memories', 'created_by'], ['subscriptions', 'user_id'],
      ['device_tokens', 'user_id'], ['notification_preferences', 'user_id'], ['couple_members', 'user_id'],
      ['notification_outbox', 'user_id'], ['invitations', 'created_by'],
    ]) {
      const { rows } = await db.admin(`select count(*)::int as n from public.${table} where ${column} = $1`, [a]);
      assert.equal(rows[0].n, 0, `${table} still holds rows for the deleted user`);
    }
    assert.equal((await db.admin('select 1 from public.storage_purge_queue where path = $1', [photo])).rows.length, 1);

    // Ben keeps his account and his own words (exportable), and can pair again.
    assert.equal((await db.query(b, 'select display_name from public.profiles'))[0].display_name, 'Ben');
    assert.deepEqual((await db.call(b, 'select public.export_my_data()')).notes.map((n) => n.body), ['from ben']);
    assert.deepEqual(await db.query(b, 'select id from public.couple_spaces'), []);
    assert.ok(await db.call(b, 'select public.create_couple_space()'));
    assert.equal((await db.admin('select status from public.couple_spaces where id = $1', [coupleId])).rows[0].status, 'ended');
  });

  test('ended spaces are purged after the retention window, and their media queued', async () => {
    const { a, coupleId, photo } = await populated();
    await db.query(a, 'select public.leave_couple()');
    await db.admin('select app_private.purge_ended_spaces()');
    assert.equal((await db.admin('select 1 from public.couple_spaces where id = $1', [coupleId])).rows.length, 1, 'kept inside the window');

    await db.admin(`update public.couple_spaces set ended_at = now() - interval '31 days' where id = $1`, [coupleId]);
    await db.admin('select app_private.purge_ended_spaces()');
    assert.equal((await db.admin('select 1 from public.notes where couple_id = $1', [coupleId])).rows.length, 0);
    assert.equal((await db.admin('select 1 from public.storage_purge_queue where path = $1', [photo])).rows.length, 1);
  });

  test('profile edits are limited to safe columns and validated', async () => {
    const { a, b } = await db.createCouple();
    await db.query(a, `update public.profiles set display_name = '  Ada L.  ', time_zone = 'Europe/Lisbon' where id = $1`, [a]);
    assert.equal((await db.query(a, 'select display_name from public.profiles where id = $1', [a]))[0].display_name, 'Ada L.');
    await db.rejects(a, `update public.profiles set time_zone = 'Nowhere/Land' where id = $1`, [a], /invalid_time_zone/);
    await db.rejects(a, `update public.profiles set id = $2 where id = $1`, [a, b], /permission denied/);
    const hijack = await db.as(a, (q) => q(`update public.profiles set display_name = 'pwned' where id = $1`, [b]));
    assert.equal(hijack.rowCount, 0);
    await db.rejects(a, 'delete from public.profiles', [], /permission denied/);
  });
});

describe('identity without sign-up', () => {
  test('an anonymous identity starts with an empty name and can do everything a member can', async () => {
    const ada = await db.createAnonymous();
    const [profile] = await db.query(ada, 'select display_name from public.profiles');
    assert.equal(profile.display_name, '');

    await db.query(ada, `update public.profiles set display_name = 'Ada' where id = $1`, [ada]);
    await db.call(ada, 'select public.create_couple_space()');
    const invite = await db.call(ada, 'select public.create_invitation()');

    const ben = await db.createAnonymous();
    const preview = await db.call(ben, 'select public.preview_invitation($1)', [invite.code]);
    assert.equal(preview.inviter_name, 'Ada');
    assert.equal((await db.call(ben, 'select public.accept_invitation($1)', [invite.code])).ok, true);
  });

  test('an anonymous identity gets no access beyond its own space', async () => {
    const { a, coupleId } = await db.createCouple();
    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'ours')`, [coupleId, a]);
    const stranger = await db.createAnonymous();
    assert.deepEqual(await db.query(stranger, 'select id from public.notes'), []);
    assert.deepEqual(await db.query(stranger, 'select id from public.couple_spaces'), []);
    assert.equal((await db.query(stranger, 'select id from public.profiles')).length, 1, 'only its own profile');
    await db.rejects(
      stranger, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'x')`, [coupleId, stranger],
      /row-level security/,
    );
  });

  test('only identities abandoned before doing anything are purged', async () => {
    const old = `now() - interval '45 days'`;
    const abandoned = await db.createAnonymous();
    const named = await db.createUser('Named');
    const recent = await db.createAnonymous();
    const inSpace = await db.createAnonymous();
    await db.call(inSpace, 'select public.create_couple_space()');
    const subscriber = await db.createAnonymous();
    await db.makePremium(subscriber);
    const backedUp = await db.createAnonymous();
    await db.admin('update auth.users set is_anonymous = false where id = $1', [backedUp]);
    await db.admin(`update auth.users set created_at = ${old} where id = any($1)`, [[abandoned, named, inSpace, subscriber, backedUp]]);

    await db.admin('select app_private.purge_abandoned_identities()');
    const { rows } = await db.admin('select id from auth.users where id = any($1)', [[abandoned, named, recent, inSpace, subscriber, backedUp]]);
    const left = new Set(rows.map((r) => r.id));
    assert.equal(left.has(abandoned), false, 'old, unnamed, never in a space: removed');
    for (const [label, id] of Object.entries({ named, recent, inSpace, subscriber, backedUp })) {
      assert.equal(left.has(id), true, `${label} must be kept`);
    }
    assert.equal((await db.admin('select 1 from public.profiles where id = $1', [abandoned])).rows.length, 0);
    await db.rejects(named, 'select app_private.purge_abandoned_identities()', [], /permission denied/);
  });
});

describe('widget tokens', () => {
  const snapshot = async (token) => (await db.asService((q) => q('select public.widget_snapshot($1) as s', [token]))).rows[0].s;

  test('a token reads exactly what the widget shows: the partner\'s latest live note', async () => {
    const { a, b, coupleId } = await db.createCouple('Ada', 'Ben');
    const token = await db.call(a, 'select public.issue_widget_token()');
    assert.match(token, /^[0-9a-f]{64}$/);
    assert.equal((await snapshot(token)).state, 'empty');

    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'my own note')`, [coupleId, a]);
    assert.equal((await snapshot(token)).state, 'empty', 'never the person\'s own notes');

    await db.query(b, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'older')`, [coupleId, b]);
    const [newer] = await db.query(b, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'newer') returning id`, [coupleId, b]);
    let s = await snapshot(token);
    assert.deepEqual([s.state, s.partner_name, s.note.body, s.note.is_unseen], ['note', 'Ben', 'newer', true]);

    // Deleting a note removes it from what the widget is given, at once.
    await db.query(b, 'select public.delete_note($1)', [newer.id]);
    s = await snapshot(token);
    assert.equal(s.note.body, 'older');
  });

  test('only the hash is stored, and clients cannot read tokens or call the snapshot directly', async () => {
    const { a } = await db.createCouple();
    const token = await db.call(a, 'select public.issue_widget_token()');
    const { rows } = await db.admin('select token_hash from public.widget_tokens where user_id = $1', [a]);
    assert.equal(rows[0].token_hash.length, 32);
    assert.ok(!rows[0].token_hash.toString('hex').includes(token.slice(0, 16)));
    await db.rejects(a, 'select * from public.widget_tokens', [], /permission denied/);
    await db.rejects(a, 'select public.widget_snapshot($1)', [token], /permission denied/);
    await assert.rejects(() => db.asAnon((q) => q('select public.issue_widget_token()')), /permission denied/);
  });

  test('unknown and revoked tokens get nothing; another person cannot revoke yours', async () => {
    const { a, b } = await db.createCouple();
    const token = await db.call(a, 'select public.issue_widget_token()');
    assert.equal(await snapshot('f'.repeat(64)), null);
    assert.equal(await snapshot(null), null);
    await db.query(b, 'select public.revoke_widget_token($1)', [token]);
    assert.notEqual(await snapshot(token), null, 'the partner cannot revoke it');
    await db.query(a, 'select public.revoke_widget_token($1)', [token]);
    assert.equal(await snapshot(token), null);
  });

  test('a token stops revealing the space once the couple unlinks, and dies with the account', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(b, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'private')`, [coupleId, b]);
    const token = await db.call(a, 'select public.issue_widget_token()');
    assert.equal((await snapshot(token)).state, 'note');

    await db.query(b, 'select public.leave_couple()');
    const after = await snapshot(token);
    assert.deepEqual(after, { state: 'unpaired' });

    await db.asService((q) => q('select public.prepare_account_deletion($1)', [a]));
    await db.admin('delete from auth.users where id = $1', [a]);
    assert.equal(await snapshot(token), null);
  });

  test('a widget registers its push token, and it is handed to the push worker', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const token = await db.call(a, 'select public.issue_widget_token()');
    const pushToken = 'ab'.repeat(80); // 80 bytes, as iOS issues
    const register = (t, p) => db.asService((q) => q('select public.set_widget_push_token($1, $2, $3) as ok', [t, p, 'sandbox'])).then((r) => r.rows[0].ok);

    assert.equal(await register(token, pushToken.toUpperCase()), true);
    assert.equal(await register('f'.repeat(64), pushToken), false, 'an unknown widget token registers nothing');
    await assert.rejects(() => register(token, 'not hex!'), /widget_tokens_push_token_check/);
    await db.rejects(a, 'select public.set_widget_push_token($1, $2, $3)', [token, pushToken, 'sandbox'], /permission denied/);

    await db.query(b, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'hi')`, [coupleId, b]);
    const claimed = (await db.asService((q) => q('select * from public.claim_notifications(50)'))).rows.find((r) => r.user_id === a);
    assert.deepEqual(claimed.widget_push, [{ token: pushToken, environment: 'sandbox' }]);

    // The same device re-registering under a newer widget token moves, not duplicates.
    const newer = await db.call(a, 'select public.issue_widget_token()');
    assert.equal(await register(newer, pushToken), true);
    const { rows } = await db.admin('select count(*)::int as n from public.widget_tokens where push_token = $1', [pushToken]);
    assert.equal(rows[0].n, 1);

    await db.asService((q) => q('select public.clear_widget_push_tokens($1)', [[pushToken]]));
    assert.equal((await db.admin('select count(*)::int as n from public.widget_tokens where push_token is not null and user_id = $1', [a])).rows[0].n, 0);
  });

  test('each identity keeps at most three tokens', async () => {
    const { a } = await db.createCouple();
    const tokens = [];
    for (let i = 0; i < 5; i += 1) tokens.push(await db.call(a, 'select public.issue_widget_token()'));
    const { rows } = await db.admin('select count(*)::int as n from public.widget_tokens where user_id = $1', [a]);
    assert.equal(rows[0].n, 3);
    assert.notEqual(await snapshot(tokens[4]), null, 'the newest still works');
  });
});
