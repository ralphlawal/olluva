// The App Review demo partner: one invitation code that is always redeemable,
// through the ordinary pairing flow, and gives access to nothing but a demo.

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { startDatabase } from './support/db.js';

const CODE = 'REVW2345AB';
const OTHER = 'ZZZZ2345AB';

describe('review partner', () => {
  let db;
  before(async () => { db = await startDatabase(); });
  after(async () => { await db.stop(); });

  const service = (sql, params) => db.asService((q) => q(sql, params)).then((r) => r.rows);
  const needed = async (code = CODE) => (await service('select public.review_partner_needed($1) as r', [code]))[0].r;
  const tick = async () => (await service('select public.review_partner_tick() as r'))[0].r;
  const expired = async () => (await service('select * from public.review_partners_expired() as id')).map((r) => r.id);
  const provision = async (code = CODE) => {
    const partner = await db.createAnonymous();
    const space = (await service('select public.review_partner_provision($1, $2) as r', [partner, code]))[0].r;
    return { partner, space };
  };
  const notesIn = async (space) => (await db.admin(
    'select author_id, body from public.notes where couple_id = $1 order by created_at, id', [space],
  )).rows;

  test('a reviewer pairs through the ordinary flow, is greeted and gets replies', async () => {
    assert.equal(await needed(), true);
    const { partner, space } = await provision();
    assert.equal(await needed(), false, 'someone is waiting behind the code');

    const reviewer = await db.createUser('Reviewer');
    const preview = await db.call(reviewer, 'select public.preview_invitation($1)', [CODE]);
    assert.equal(preview.ok, true);
    assert.equal(preview.inviter_name, 'Demo Partner');
    const accepted = await db.call(reviewer, 'select public.accept_invitation($1)', ['revw2-345ab']);
    assert.equal(accepted.ok, true);
    assert.equal(accepted.couple_id, space);

    assert.equal(await tick(), 1);
    assert.match((await notesIn(space))[0].body, /demo partner/);
    assert.equal(await tick(), 0, 'it does not talk to itself');

    await db.query(reviewer, 'insert into public.notes (couple_id, author_id, body) values ($1, $2, $3)', [space, reviewer, 'hello']);
    assert.equal(await tick(), 1);
    const notes = await notesIn(space);
    assert.equal(notes.length, 3);
    assert.equal(notes[2].author_id, partner);
    // The reviewer is told about it like any other note.
    const pushes = await db.admin(`select count(*)::int as n from public.notification_outbox where user_id = $1 and category = 'new_note'`, [reviewer]);
    assert.equal(pushes.rows[0].n, 2);

    // The code has been used, so it needs someone new; the same code works again.
    assert.equal(await needed(), true);
    const second = await provision();
    assert.equal(await needed(), false);
    const another = await db.createUser('Second reviewer');
    assert.equal((await db.call(another, 'select public.accept_invitation($1)', [CODE])).couple_id, second.space);
    assert.notEqual(second.space, space);

    // Each reviewer sees their own demo space and nothing of the other's.
    assert.equal((await db.query(another, 'select id from public.notes where couple_id = $1', [space])).length, 0);
    assert.equal((await db.query(reviewer, 'select id from public.notes where couple_id = $1', [second.space])).length, 0);
  });

  test('the demo partner answers the daily question so a reviewer can open it', async () => {
    const { space } = await provision('TOGR2345AB');
    const reviewer = await db.createUser('Reviewer');
    await db.call(reviewer, 'select public.accept_invitation($1)', ['TOGR2345AB']);
    const moment = await db.call(reviewer, 'select public.together_today()');
    assert.equal(moment.partner_answered, false);

    await tick();
    const after = await db.call(reviewer, 'select public.together_today()');
    assert.equal(after.partner_answered, true);
    assert.equal(after.partner_answer, null, 'still sealed until opened');
    await tick();
    const answers = await db.admin('select count(*)::int as n from public.together_answers where moment_id = $1', [moment.id]);
    assert.equal(answers.rows[0].n, 1, 'answered once');

    const ready = await db.call(reviewer, 'select public.together_submit($1, $2)', [moment.id, 'mine']);
    assert.equal(ready.status, 'ready');
    const opened = await db.call(reviewer, 'select public.together_reveal($1)', [moment.id]);
    assert.ok(opened.partner_answer.length > 10);
    assert.ok(space);

    // A real couple's question is never touched.
    const real = await db.createCouple();
    const theirs = await db.call(real.a, 'select public.together_today()');
    await tick();
    assert.equal((await db.call(real.a, 'select public.together_moment($1)', [theirs.id])).partner_answered, false);
  });

  test('replies are bounded', async () => {
    const { space } = await provision(OTHER);
    const reviewer = await db.createUser('Chatty');
    await db.call(reviewer, 'select public.accept_invitation($1)', [OTHER]);
    await tick();
    for (let i = 0; i < 30; i += 1) {
      await db.query(reviewer, 'insert into public.notes (couple_id, author_id, body) values ($1, $2, $3)', [space, reviewer, `n${i}`]);
      await tick();
    }
    const partnerNotes = (await notesIn(space)).filter((n) => n.author_id !== reviewer);
    assert.equal(partnerNotes.length, 25);
  });

  test('finished demo partners are cleared; the waiting one never is', async () => {
    const waiting = await provision('WAXT2345AB');
    assert.equal((await expired()).includes(waiting.partner), false);

    const left = await provision('LEFT2345AB');
    const reviewer = await db.createUser('Leaver');
    await db.call(reviewer, 'select public.accept_invitation($1)', ['LEFT2345AB']);
    assert.equal((await expired()).includes(left.partner), false, 'in use');
    await db.query(reviewer, 'select public.leave_couple(false)');
    assert.equal((await expired()).includes(left.partner), true, 'the other person left');

    const old = await provision('OLDD2345AB');
    const stayer = await db.createUser('Stayer');
    await db.call(stayer, 'select public.accept_invitation($1)', ['OLDD2345AB']);
    await db.admin(`update public.review_partners set created_at = now() - interval '15 days' where user_id = $1`, [old.partner]);
    assert.equal((await expired()).includes(old.partner), true, 'older than two weeks');
  });

  test('retiring the code stops new pairings', async () => {
    await provision('RETR2345AB');
    assert.ok((await service('select public.review_partner_retire() as r'))[0].r >= 1);
    const reviewer = await db.createUser('Late');
    assert.equal((await db.call(reviewer, 'select public.accept_invitation($1)', ['RETR2345AB'])).ok, false);
  });

  test('it never takes over a code a real person holds, and only fresh identities qualify', async () => {
    const real = await db.createUser('Real');
    await db.call(real, 'select public.create_couple_space()');
    const invite = await db.call(real, 'select public.create_invitation()');
    assert.equal(await needed(invite.code), false);
    const fresh = await db.createAnonymous();
    await assert.rejects(() => service('select public.review_partner_provision($1, $2)', [fresh, invite.code]), /code_in_use/);
    await assert.rejects(() => service('select public.review_partner_provision($1, $2)', [real, 'FRSH2345AB']), /identity_not_fresh/);
    await assert.rejects(() => service('select public.review_partner_provision($1, $2)', [fresh, 'short']), /invalid_code/);
    assert.equal(await needed('short'), false);
  });

  test('there is a daily allowance', async () => {
    const count = (await db.admin(`select count(*)::int as n from public.review_partners where created_at > now() - interval '1 day'`)).rows[0].n;
    for (let i = count; i < 30; i += 1) {
      const id = await db.createAnonymous();
      await db.admin('insert into public.review_partners (user_id) values ($1)', [id]);
    }
    assert.equal(await needed('FULL2345AB'), false);
  });

  test('none of it is reachable by an app user', async () => {
    const user = await db.createUser('Curious');
    await db.rejects(user, 'select public.review_partner_needed($1)', [CODE], /permission denied/);
    await db.rejects(user, 'select public.review_partner_provision($1, $2)', [user, CODE], /permission denied/);
    await db.rejects(user, 'select public.review_partner_tick()', [], /permission denied/);
    await db.rejects(user, 'select public.review_partner_retire()', [], /permission denied/);
    await db.rejects(user, 'select * from public.review_partners_expired()', [], /permission denied/);
    await db.rejects(user, 'select * from public.review_partners', [], /permission denied/);
  });
});
