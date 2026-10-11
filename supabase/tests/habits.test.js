// The streak, and reporting a note.

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { startDatabase } from './support/db.js';

describe('streak and reports', () => {
  let db;
  before(async () => { db = await startDatabase(); });
  after(async () => { await db.stop(); });

  const streak = (user) => db.call(user, 'select public.get_streak()');
  // A note written `daysAgo` days back, at midday UTC so the day is unambiguous.
  const wrote = (space, author, daysAgo) => db.admin(
    `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'x') returning id`, [space, author],
  ).then((r) => db.admin(
    `update public.notes set created_at = date_trunc('day', now() at time zone 'UTC') + interval '12 hours' - make_interval(days => $2) where id = $1`,
    [r.rows[0].id, daysAgo],
  ));

  test('a day counts only when both wrote, and today is not held against you', async () => {
    const { a, b, coupleId } = await db.createCouple();
    assert.deepEqual(await streak(a), { days: 0, me_today: false, partner_today: false });

    for (const day of [1, 2, 3]) { await wrote(coupleId, a, day); await wrote(coupleId, b, day); }
    // Three full days behind us, nothing yet today: still a streak of three.
    assert.equal((await streak(a)).days, 3);

    await wrote(coupleId, a, 0);
    assert.deepEqual(await streak(a), { days: 3, me_today: true, partner_today: false });
    assert.deepEqual(await streak(b), { days: 3, me_today: false, partner_today: true });

    await wrote(coupleId, b, 0);
    assert.deepEqual(await streak(a), { days: 4, me_today: true, partner_today: true });
  });

  test('a gap, or a day only one of you wrote, ends it', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await wrote(coupleId, a, 1); await wrote(coupleId, b, 1);
    await wrote(coupleId, a, 2);                       // only one of them
    await wrote(coupleId, a, 3); await wrote(coupleId, b, 3);
    assert.equal((await streak(a)).days, 1);

    const other = await db.createCouple();
    await wrote(other.coupleId, other.a, 2); await wrote(other.coupleId, other.b, 2);
    assert.equal((await streak(other.a)).days, 0, 'yesterday was missed');
  });

  test('a streak belongs to a space; someone with none has none', async () => {
    const loner = await db.createUser('Solo');
    assert.deepEqual(await streak(loner), { days: 0, me_today: false, partner_today: false });
    await db.asAnon((q) => q('select 1')).then(() => null);
    await assert.rejects(() => db.asAnon((q) => q('select public.get_streak()')), /permission denied/);
  });

  test('a received note can be reported once; nothing else can', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const outsider = await db.createUser('Zed');
    const note = (await db.query(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'unkind') returning id`, [coupleId, a]))[0].id;

    await db.query(b, 'select public.report_note($1)', [note]);
    await db.query(b, 'select public.report_note($1)', [note]);
    const reports = (await db.admin('select reporter_id, author_id, body from public.note_reports where note_id = $1', [note])).rows;
    assert.deepEqual(reports, [{ reporter_id: b, author_id: a, body: 'unkind' }]);

    await db.rejects(a, 'select public.report_note($1)', [note], /not_allowed/);
    await db.rejects(outsider, 'select public.report_note($1)', [note], /note_not_found/);
    // Reports are for the operator only.
    await db.rejects(b, 'select * from public.note_reports', [], /permission denied/);
    await db.rejects(a, 'select * from public.note_reports', [], /permission denied/);
    // The author is not told.
    const told = await db.admin(`select count(*)::int as n from public.notification_outbox where user_id = $1 and created_at > now() - interval '5 seconds' and category <> 'new_note' and category <> 'pairing'`, [a]);
    assert.equal(told.rows[0].n, 0);
  });
});
