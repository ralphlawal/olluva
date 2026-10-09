import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { startDatabase } from './support/db.js';

let db;
before(async () => { db = await startDatabase(); });
after(async () => { await db?.stop(); });

async function soloWithInvite(name = 'Ada') {
  const user = await db.createUser(name);
  const coupleId = await db.call(user, 'select public.create_couple_space()');
  const invite = await db.call(user, 'select public.create_invitation()');
  return { user, coupleId, invite };
}

const activeMembers = async (coupleId) =>
  (await db.admin('select user_id from public.couple_members where couple_id = $1 and left_at is null', [coupleId])).rows;

describe('account bootstrap', () => {
  test('a new auth user gets a profile and private-by-default notification preferences', async () => {
    const user = await db.createUser('Ada');
    const [profile] = await db.query(user, 'select display_name from public.profiles');
    assert.equal(profile.display_name, 'Ada');
    const [prefs] = await db.query(user, 'select show_previews, new_notes from public.notification_preferences');
    assert.deepEqual(prefs, { show_previews: false, new_notes: true });
  });
});

describe('invitation codes', () => {
  test('are 10 characters from the unambiguous alphabet and are stored only as a hash', async () => {
    const { invite } = await soloWithInvite();
    assert.match(invite.code, /^[2-9A-HJ-NP-Z]{10}$/);
    const { rows } = await db.admin('select code_hash from public.invitations where id = $1', [invite.id]);
    assert.equal(rows[0].code_hash.length, 32);
    assert.ok(!rows[0].code_hash.toString('utf8').includes(invite.code));
  });

  test('the hash column is not readable through the API, even by the creator', async () => {
    const { user } = await soloWithInvite();
    await db.rejects(user, 'select code_hash from public.invitations', [], /permission denied/);
    const rows = await db.query(user, 'select id, status from public.invitations');
    assert.equal(rows.length, 1);
  });

  test('nobody else can list an invitation', async () => {
    await soloWithInvite();
    const stranger = await db.createUser('Eve');
    assert.deepEqual(await db.query(stranger, 'select id from public.invitations'), []);
  });

  test('typing variations of the same code are accepted', async () => {
    const { invite } = await soloWithInvite();
    const joiner = await db.createUser('Ben');
    const typed = `${invite.code.slice(0, 5).toLowerCase()} - ${invite.code.slice(5).toLowerCase()}`;
    const preview = await db.call(joiner, 'select public.preview_invitation($1)', [typed]);
    assert.equal(preview.ok, true);
    assert.equal(preview.inviter_name, 'Ada');
  });

  test('issuing a new code revokes the previous one', async () => {
    const { user, invite } = await soloWithInvite();
    const second = await db.call(user, 'select public.create_invitation()');
    assert.notEqual(second.code, invite.code);
    const joiner = await db.createUser('Ben');
    const old = await db.call(joiner, 'select public.accept_invitation($1)', [invite.code]);
    assert.deepEqual(old, { ok: false, error: 'invitation_unavailable' });
    const fresh = await db.call(joiner, 'select public.accept_invitation($1)', [second.code]);
    assert.equal(fresh.ok, true);
  });
});

describe('pairing', () => {
  test('accepting an invitation creates a two-person space', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const members = (await activeMembers(coupleId)).map((m) => m.user_id).sort();
    assert.deepEqual(members, [a, b].sort());
    const [space] = await db.query(b, 'select id, status, paired_at from public.couple_spaces');
    assert.equal(space.id, coupleId);
    assert.ok(space.paired_at);
  });

  test('partners can read each other\'s profile; strangers cannot', async () => {
    const { a, b } = await db.createCouple('Ada', 'Ben');
    const stranger = await db.createUser('Eve');
    const seenByA = await db.query(a, 'select display_name from public.profiles order by display_name');
    assert.deepEqual(seenByA.map((r) => r.display_name), ['Ada', 'Ben']);
    const seenByStranger = await db.query(stranger, 'select id from public.profiles where id = any($1)', [[a, b]]);
    assert.deepEqual(seenByStranger, []);
  });

  test('an invitation is single use', async () => {
    const { invite } = await soloWithInvite();
    const first = await db.createUser('Ben');
    const second = await db.createUser('Cal');
    assert.equal((await db.call(first, 'select public.accept_invitation($1)', [invite.code])).ok, true);
    assert.deepEqual(
      await db.call(second, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'invitation_unavailable' },
    );
  });

  test('you cannot accept your own invitation', async () => {
    const { user, invite } = await soloWithInvite();
    assert.deepEqual(
      await db.call(user, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'own_invitation' },
    );
  });

  test('a paired user cannot join a second couple', async () => {
    const { a } = await db.createCouple();
    const { invite } = await soloWithInvite('Cal');
    assert.deepEqual(
      await db.call(a, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'already_paired' },
    );
    await db.rejects(a, 'select public.create_couple_space()', [], /already_in_space/);
  });

  test('a paired couple cannot issue further invitations', async () => {
    const { a } = await db.createCouple();
    await db.rejects(a, 'select public.create_invitation()', [], /already_paired/);
  });

  test('expired invitations are refused and marked expired', async () => {
    const { invite } = await soloWithInvite();
    await db.admin(`update public.invitations set expires_at = now() - interval '1 minute' where id = $1`, [invite.id]);
    const joiner = await db.createUser('Ben');
    assert.deepEqual(
      await db.call(joiner, 'select public.preview_invitation($1)', [invite.code]),
      { ok: false, error: 'invitation_expired' },
    );
    assert.deepEqual(
      await db.call(joiner, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'invitation_expired' },
    );
    const { rows } = await db.admin('select status from public.invitations where id = $1', [invite.id]);
    assert.equal(rows[0].status, 'expired');
  });

  test('revoked invitations are refused, and only the creator can revoke', async () => {
    const { user, invite } = await soloWithInvite();
    const joiner = await db.createUser('Ben');
    await db.rejects(joiner, 'select public.revoke_invitation($1)', [invite.id], /invitation_unavailable/);
    await db.query(user, 'select public.revoke_invitation($1)', [invite.id]);
    assert.deepEqual(
      await db.call(joiner, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'invitation_unavailable' },
    );
  });

  test('declining an invitation consumes it without pairing', async () => {
    const { user, coupleId, invite } = await soloWithInvite();
    const joiner = await db.createUser('Ben');
    assert.equal((await db.call(joiner, 'select public.decline_invitation($1)', [invite.code])).ok, true);
    assert.equal((await activeMembers(coupleId)).length, 1);
    const [row] = await db.query(user, 'select status from public.invitations where id = $1', [invite.id]);
    assert.equal(row.status, 'declined');
  });

  test('joining a partner closes the joiner\'s own empty space', async () => {
    const mine = await soloWithInvite('Ben');
    const theirs = await soloWithInvite('Ada');
    const result = await db.call(mine.user, 'select public.accept_invitation($1)', [theirs.invite.code]);
    assert.equal(result.couple_id, theirs.coupleId);
    const { rows } = await db.admin('select status from public.couple_spaces where id = $1', [mine.coupleId]);
    assert.equal(rows[0].status, 'ended');
    // The code for the closed space is dead too.
    const third = await db.createUser('Cal');
    assert.deepEqual(
      await db.call(third, 'select public.accept_invitation($1)', [mine.invite.code]),
      { ok: false, error: 'invitation_unavailable' },
    );
  });
});

describe('pairing under concurrency', () => {
  test('two people racing for one invitation: exactly one joins', async () => {
    for (let round = 0; round < 5; round += 1) {
      const { coupleId, invite } = await soloWithInvite();
      const racers = await Promise.all([db.createUser('Ben'), db.createUser('Cal'), db.createUser('Dee')]);
      const results = await Promise.all(
        racers.map((u) => db.call(u, 'select public.accept_invitation($1)', [invite.code])),
      );
      assert.equal(results.filter((r) => r.ok).length, 1, JSON.stringify(results));
      assert.equal((await activeMembers(coupleId)).length, 2);
    }
  });

  test('partners redeeming each other\'s codes at the same moment end up in one shared space', async () => {
    for (let round = 0; round < 8; round += 1) {
      const ada = await soloWithInvite('Ada');
      const ben = await soloWithInvite('Ben');
      const [r1, r2] = await Promise.all([
        db.call(ada.user, 'select public.accept_invitation($1)', [ben.invite.code]),
        db.call(ben.user, 'select public.accept_invitation($1)', [ada.invite.code]),
      ]);
      assert.equal([r1, r2].filter((r) => r.ok).length, 1, JSON.stringify([r1, r2]));
      assert.equal([r1, r2].find((r) => !r.ok).error, 'already_paired');

      const { rows } = await db.admin(
        `select couple_id, count(*)::int as n from public.couple_members
         where user_id = any($1) and left_at is null group by couple_id`,
        [[ada.user, ben.user]],
      );
      assert.equal(rows.length, 1);
      assert.equal(rows[0].n, 2);
    }
  });

  test('one account accepting two different invitations at once joins only one', async () => {
    const one = await soloWithInvite('Ada');
    const two = await soloWithInvite('Cal');
    const joiner = await db.createUser('Ben');
    const results = await Promise.all([
      db.call(joiner, 'select public.accept_invitation($1)', [one.invite.code]),
      db.call(joiner, 'select public.accept_invitation($1)', [two.invite.code]),
    ]);
    assert.equal(results.filter((r) => r.ok).length, 1);
    const { rows } = await db.admin(
      'select count(*)::int as n from public.couple_members where user_id = $1 and left_at is null', [joiner],
    );
    assert.equal(rows[0].n, 1);
  });
});

describe('invitation abuse', () => {
  test('guessing codes is rate limited per account, and the limit survives failed calls', async () => {
    const { invite } = await soloWithInvite();
    const attacker = await db.createUser('Eve');
    for (let i = 0; i < 5; i += 1) {
      const guess = await db.call(attacker, 'select public.accept_invitation($1)', [`WRONG${i}WRONG`]);
      assert.equal(guess.error, 'invitation_unavailable');
    }
    // Even the correct code is refused once the limiter has tripped.
    assert.deepEqual(
      await db.call(attacker, 'select public.accept_invitation($1)', [invite.code]),
      { ok: false, error: 'rate_limited' },
    );
    assert.deepEqual(
      await db.call(attacker, 'select public.preview_invitation($1)', [invite.code]),
      { ok: false, error: 'rate_limited' },
    );
    // The window passes; the account can try again.
    await db.admin(`update public.invitation_attempts set attempted_at = now() - interval '16 minutes' where user_id = $1`, [attacker]);
    assert.equal((await db.call(attacker, 'select public.preview_invitation($1)', [invite.code])).ok, true);
  });

  test('issuing invitations is rate limited', async () => {
    const { user } = await soloWithInvite();
    for (let i = 0; i < 9; i += 1) {
      await db.call(user, 'select public.create_invitation()');
    }
    await db.rejects(user, 'select public.create_invitation()', [], /rate_limited/);
  });

  test('a missing code and a dead code are indistinguishable', async () => {
    const { user, invite } = await soloWithInvite();
    await db.query(user, 'select public.revoke_invitation($1)', [invite.id]);
    const prober = await db.createUser('Eve');
    const dead = await db.call(prober, 'select public.preview_invitation($1)', [invite.code]);
    const missing = await db.call(prober, 'select public.preview_invitation($1)', ['ZZZZZZZZZZ']);
    assert.deepEqual(dead, missing);
  });

  test('membership cannot be written directly', async () => {
    const { coupleId } = await soloWithInvite();
    const attacker = await db.createUser('Eve');
    await db.rejects(
      attacker, 'insert into public.couple_members (couple_id, user_id) values ($1, $2)', [coupleId, attacker],
      /permission denied/,
    );
    await db.rejects(attacker, 'update public.couple_members set left_at = now()', [], /permission denied/);
    await db.rejects(attacker, `update public.couple_spaces set status = 'ended'`, [], /permission denied/);
    await db.rejects(attacker, `update public.invitations set status = 'pending'`, [], /permission denied/);
  });
});

describe('unlinking and blocking', () => {
  test('unlinking ends the space for both partners at once', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'hello')`, [coupleId, a]);
    await db.query(b, 'select public.leave_couple()');

    for (const user of [a, b]) {
      assert.deepEqual(await db.query(user, 'select id from public.couple_spaces'), []);
      assert.deepEqual(await db.query(user, 'select id from public.notes'), []);
    }
    // Neither account was deleted, and both are free to pair again.
    assert.equal((await db.admin('select count(*)::int as n from public.profiles where id = any($1)', [[a, b]])).rows[0].n, 2);
    assert.ok(await db.call(a, 'select public.create_couple_space()'));
  });

  test('a blocked account cannot pair with the blocker again, in either direction', async () => {
    const { a, b } = await db.createCouple();
    await db.query(a, 'select public.leave_couple(true)');

    await db.call(a, 'select public.create_couple_space()');
    const fromA = await db.call(a, 'select public.create_invitation()');
    assert.deepEqual(
      await db.call(b, 'select public.accept_invitation($1)', [fromA.code]),
      { ok: false, error: 'invitation_unavailable' },
    );

    await db.call(b, 'select public.create_couple_space()');
    const fromB = await db.call(b, 'select public.create_invitation()');
    assert.deepEqual(
      await db.call(a, 'select public.preview_invitation($1)', [fromB.code]),
      { ok: false, error: 'invitation_unavailable' },
    );

    // The blocker can see and lift their own block; the blocked party sees nothing.
    assert.equal((await db.query(a, 'select blocked_id from public.blocks')).length, 1);
    assert.deepEqual(await db.query(b, 'select blocked_id from public.blocks'), []);
    await db.query(a, 'delete from public.blocks where blocked_id = $1', [b]);
    assert.equal((await db.call(a, 'select public.preview_invitation($1)', [fromB.code])).ok, true);
  });
});

describe('anonymous access', () => {
  test('the anon role can read nothing and call nothing', async () => {
    await db.createCouple();
    for (const table of [
      'profiles', 'couple_spaces', 'couple_members', 'invitations', 'notes', 'note_reactions',
      'memories', 'important_dates', 'scheduled_messages', 'subscriptions', 'device_tokens',
      'notification_preferences', 'notification_outbox', 'audit_events', 'blocks',
      'invitation_attempts', 'storage_purge_queue', 'themes',
    ]) {
      await assert.rejects(
        () => db.asAnon((q) => q(`select * from public.${table} limit 1`)),
        /permission denied/, `anon could read ${table}`,
      );
    }
    for (const call of [
      'public.create_couple_space()', `public.accept_invitation('AAAAAAAAAA')`,
      'public.get_entitlement()', 'public.export_my_data()', 'public.claim_notifications(1)',
    ]) {
      await assert.rejects(() => db.asAnon((q) => q(`select ${call}`)), /permission denied/, `anon could call ${call}`);
    }
  });

  test('every table in the public schema has row level security enabled', async () => {
    const { rows } = await db.admin(
      `select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`,
    );
    assert.deepEqual(rows, []);
  });

  test('no function in the public schema is executable by PUBLIC or anon', async () => {
    const { rows } = await db.admin(
      `select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app_private')
         and (has_function_privilege('anon', p.oid, 'execute')
              or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))`,
    );
    assert.deepEqual(rows, []);
  });
});
