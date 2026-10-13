// Olluva Together: one question a day, answered separately, revealed together.
// These run against a real Postgres with every migration applied, as the API
// roles, so they exercise the actual access rules rather than a description
// of them.

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { startDatabase } from './support/db.js';

describe('together', () => {
  let db;
  before(async () => { db = await startDatabase(); });
  after(async () => { await db.stop(); });

  const today = (user) => db.call(user, 'select public.together_today()');
  const submit = (user, moment, body) => db.call(user, 'select public.together_submit($1, $2)', [moment, body]);
  const reveal = (user, moment) => db.call(user, 'select public.together_reveal($1)', [moment]);
  const moment = (user, id) => db.call(user, 'select public.together_moment($1)', [id]);
  const history = (user, before = null, limit = 20) => db.call(user, 'select public.together_history($1, $2)', [before, limit]);
  const outbox = async (user) => (await db.admin(
    `select payload ->> 'event' as event, payload from public.notification_outbox where user_id = $1 and category = 'together' order by id`, [user],
  )).rows;
  /** Moves a moment into the past, as if it had been created that many days ago. */
  const age = (id, days) => db.admin('update public.together_moments set day = day - $2::int where id = $1', [id, days]);
  /** A couple with a moment both have answered and revealed. */
  const completed = async () => {
    const couple = await db.createCouple();
    const m = await today(couple.a);
    await submit(couple.a, m.id, 'from a');
    await submit(couple.b, m.id, 'from b');
    await reveal(couple.a, m.id);
    return { ...couple, id: m.id };
  };

  test('both partners get the same moment and the same question, once per day', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const [one, two, three] = await Promise.all([today(a), today(b), today(a)]);
    assert.equal(one.id, two.id);
    assert.equal(one.id, three.id);
    assert.deepEqual(one.question, two.question);
    assert.equal(one.status, 'open');
    assert.match(one.question.body, /\?$/);
    const rows = await db.admin('select count(*)::int as n from public.together_moments where couple_id = $1', [coupleId]);
    assert.equal(rows.rows[0].n, 1);
    await assert.rejects(
      () => db.admin('insert into public.together_moments (couple_id, day, question_id) values ($1, $2, 1)', [coupleId, one.day]),
      /duplicate key/,
    );
  });

  test('the day is the couple’s, not each phone’s', async () => {
    const { a, b } = await db.createCouple();
    await db.admin(`update public.profiles set time_zone = 'Pacific/Kiritimati' where id = $1`, [a]);
    await db.admin(`update public.profiles set time_zone = 'Pacific/Pago_Pago' where id = $1`, [b]);
    const mine = await today(a);
    const theirs = await today(b);
    assert.equal(mine.id, theirs.id);
    assert.equal(mine.day, theirs.day);
    // Fixed by whoever opened it first, and it stays fixed.
    const zone = await db.admin(
      'select time_zone from public.together_settings where couple_id = (select couple_id from public.together_moments where id = $1)', [mine.id],
    );
    assert.equal(zone.rows[0].time_zone, 'Pacific/Kiritimati');
  });

  test('questions do not repeat for sixty days and vary in kind', async () => {
    const { a, coupleId } = await db.createCouple();
    const pick = async (day) => (await db.admin(
      'select app_private.together_pick_question($1, $2::date) as id', [coupleId, day],
    )).rows[0].id;
    const start = new Date(Date.UTC(2027, 0, 1));
    const asked = [];
    for (let i = 0; i < 70; i += 1) {
      const day = new Date(start.getTime() + i * 86_400_000).toISOString().slice(0, 10);
      const id = await pick(day);
      assert.equal(id, await pick(day), 'the same day always gives the same question');
      await db.admin('insert into public.together_moments (couple_id, day, question_id) values ($1, $2, $3)', [coupleId, day, id]);
      asked.push(id);
    }
    for (let i = 0; i < asked.length; i += 1) {
      const window = asked.slice(Math.max(0, i - 60), i);
      assert.equal(window.includes(asked[i]), false, `question ${asked[i]} repeated within sixty days at step ${i}`);
    }
    const categories = (await db.admin(
      `select q.category from public.together_moments m join public.together_questions q on q.id = m.question_id
       where m.couple_id = $1 order by m.day`, [coupleId],
    )).rows.map((r) => r.category);
    const sameAsPrevious = categories.filter((c, i) => i > 0 && c === categories[i - 1]).length;
    assert.equal(sameAsPrevious, 0, 'consecutive days should differ in category while unused questions allow it');
    // A different couple is not given the same sequence.
    const other = await db.createCouple();
    const theirs = (await db.admin('select app_private.together_pick_question($1, $2::date) as id', [other.coupleId, '2027-01-01'])).rows[0].id;
    const second = (await db.admin('select app_private.together_pick_question($1, $2::date) as id', [other.coupleId, '2027-01-02'])).rows[0].id;
    assert.notDeepEqual([theirs, second], asked.slice(0, 2));
    assert.ok(a);
  });

  test('answers are independent, and nothing gives one away before the reveal', async () => {
    const { a, b } = await db.createCouple();
    const m = await today(a);

    const mine = await submit(a, m.id, '  You made me tea without asking.  ');
    assert.equal(mine.status, 'waiting');
    assert.equal(mine.my_answer, 'You made me tea without asking.');
    assert.equal(mine.partner_answered, false);

    // Every way b can ask, b learns only that a has answered.
    for (const view of [await today(b), await moment(b, m.id)]) {
      assert.equal(view.status, 'open');
      assert.equal(view.partner_answered, true);
      assert.equal(view.partner_answer, null);
      assert.equal(view.my_answer, null);
      assert.equal(JSON.stringify(view).includes('tea'), false);
    }
    assert.deepEqual(await history(b), []);

    const theirs = await submit(b, m.id, 'When you waited up for me.');
    assert.equal(theirs.status, 'ready');
    assert.equal(theirs.partner_answer, null, 'ready is not revealed');
    for (const user of [a, b]) {
      const listed = await history(user);
      assert.equal(listed.length, 1);
      assert.equal(listed[0].status, 'ready');
      assert.equal(listed[0].partner_answer, null);
    }
    // Each still sees only their own words.
    assert.equal((await moment(a, m.id)).my_answer, 'You made me tea without asking.');
    assert.equal((await moment(b, m.id)).my_answer, 'When you waited up for me.');
  });

  test('the tables themselves give nothing away', async () => {
    const { a, b, id } = await completed();
    const fresh = await db.createCouple();
    const open = await today(fresh.a);
    await submit(fresh.a, open.id, 'private until revealed');

    for (const user of [a, fresh.a, fresh.b]) {
      await db.rejects(user, 'select * from public.together_answers', [], /permission denied/);
      await db.rejects(user, 'select body from public.together_answers where moment_id = $1', [open.id], /permission denied/);
      await db.rejects(user, `insert into public.together_answers (moment_id, user_id, body) values ($1, $2, 'x')`, [open.id, user], /permission denied/);
      await db.rejects(user, `update public.together_answers set body = 'x'`, [], /permission denied/);
      await db.rejects(user, 'delete from public.together_answers', [], /permission denied/);
      await db.rejects(user, 'select * from public.together_questions', [], /permission denied/);
      await db.rejects(user, 'select * from public.together_settings', [], /permission denied/);
      await db.rejects(user, `update public.together_moments set revealed_at = now()`, [], /permission denied/);
      await db.rejects(user, `insert into public.together_moments (couple_id, day, question_id) values (gen_random_uuid(), current_date, 1)`, [], /permission denied/);
      await db.rejects(user, 'select app_private.together_state(m, $1) from public.together_moments m', [user], /permission denied/);
    }
    // The readable table has no column that could hold an answer.
    const visible = await db.query(fresh.b, 'select * from public.together_moments');
    assert.equal(visible.length, 1);
    assert.deepEqual(Object.keys(visible[0]).sort(), [
      'answer_count', 'couple_id', 'created_at', 'day', 'id', 'question_id', 'ready_at', 'revealed_at', 'revealed_by', 'updated_at',
    ]);
    assert.equal(visible[0].answer_count, 1);
    await assert.rejects(() => db.asAnon((q) => q('select public.together_today()')), /permission denied/);
    await assert.rejects(() => db.asAnon((q) => q('select * from public.together_moments')), /permission denied/);
    assert.ok(b && id);
  });

  test('another couple cannot see, answer, reveal or save a moment', async () => {
    const mine = await completed();
    const { a, b } = await db.createCouple();
    const open = await today(a);
    await submit(a, open.id, 'ours');
    await submit(b, open.id, 'also ours');
    const stranger = mine.a;
    const loner = await db.createUser('Solo');

    for (const user of [stranger, loner]) {
      await db.rejects(user, 'select public.together_moment($1)', [open.id], /moment_not_found/);
      await db.rejects(user, 'select public.together_submit($1, $2)', [open.id, 'intrusion'], /moment_not_found/);
      await db.rejects(user, 'select public.together_reveal($1)', [open.id], /moment_not_found/);
      await db.rejects(user, 'select public.together_save_memory($1)', [open.id], /moment_not_found/);
      await db.rejects(user, 'select public.together_unsave_memory($1)', [open.id], /moment_not_found/);
      assert.equal((await db.query(user, 'select id from public.together_moments where id = $1', [open.id])).length, 0);
    }
    assert.equal((await history(stranger)).some((m) => m.id === open.id), false);
    assert.deepEqual(await history(loner), []);
    assert.deepEqual(await today(loner), { status: 'unpaired' });
    // And it is untouched.
    const still = await moment(a, open.id);
    assert.equal(still.status, 'ready');
    assert.equal(still.my_answer, 'ours');
  });

  test('an answer can be edited until the reveal, within limits, and never after', async () => {
    const { a, b } = await db.createCouple();
    const m = await today(a);
    await db.rejects(a, 'select public.together_submit($1, $2)', [m.id, '   '], /invalid_answer/);
    await db.rejects(a, 'select public.together_submit($1, $2)', [m.id, null], /invalid_answer/);
    await db.rejects(a, 'select public.together_submit($1, $2)', [m.id, 'x'.repeat(501)], /invalid_answer/);
    assert.equal((await submit(a, m.id, 'x'.repeat(500))).my_answer.length, 500);

    assert.equal((await submit(a, m.id, 'second thoughts')).my_answer, 'second thoughts');
    await submit(b, m.id, 'b first');
    // Still editable while it waits to be revealed, and b's is not touched.
    assert.equal((await submit(a, m.id, 'final')).status, 'ready');
    assert.equal((await moment(b, m.id)).my_answer, 'b first');
    const stored = await db.admin('select count(*)::int as n from public.together_answers where moment_id = $1', [m.id]);
    assert.equal(stored.rows[0].n, 2);

    await reveal(b, m.id);
    await db.rejects(a, 'select public.together_submit($1, $2)', [m.id, 'too late'], /already_revealed/);
    assert.equal((await moment(b, m.id)).partner_answer, 'final');
  });

  test('reveal needs both answers, opens for both at once, and happens once', async () => {
    const { a, b } = await db.createCouple();
    const m = await today(a);
    await db.rejects(a, 'select public.together_reveal($1)', [m.id], /not_ready/);
    await submit(a, m.id, 'alpha');
    await db.rejects(a, 'select public.together_reveal($1)', [m.id], /not_ready/);
    await db.rejects(b, 'select public.together_reveal($1)', [m.id], /not_ready/);
    assert.equal((await moment(b, m.id)).partner_answer, null);
    await submit(b, m.id, 'beta');

    const opened = await reveal(b, m.id);
    assert.equal(opened.status, 'revealed');
    assert.equal(opened.my_answer, 'beta');
    assert.equal(opened.partner_answer, 'alpha');
    // The other phone finds the same state without doing anything.
    const other = await today(a);
    assert.equal(other.status, 'revealed');
    assert.equal(other.partner_answer, 'beta');
    assert.equal(other.revealed_at, opened.revealed_at);

    const again = await reveal(a, m.id);
    assert.equal(again.revealed_at, opened.revealed_at);
    const row = (await db.admin('select revealed_by from public.together_moments where id = $1', [m.id])).rows[0];
    assert.equal(row.revealed_by, b);
  });

  test('simultaneous answers and simultaneous reveals leave one consistent state', async () => {
    for (let round = 0; round < 5; round += 1) {
      const { a, b } = await db.createCouple();
      const m = await today(a);
      const [first, second] = await Promise.all([submit(a, m.id, `a${round}`), submit(b, m.id, `b${round}`)]);
      assert.deepEqual([first.status, second.status].sort(), ['ready', 'waiting']);
      const row = (await db.admin('select answer_count, ready_at from public.together_moments where id = $1', [m.id])).rows[0];
      assert.equal(row.answer_count, 2);
      assert.ok(row.ready_at);

      const reveals = await Promise.all([reveal(a, m.id), reveal(b, m.id), reveal(a, m.id)]);
      assert.equal(new Set(reveals.map((r) => r.revealed_at)).size, 1);
      assert.equal(reveals[0].partner_answer, `b${round}`);
      assert.equal(reveals[1].partner_answer, `a${round}`);
      const audits = await db.admin(
        `select count(*)::int as n from public.audit_events where event = 'together_revealed' and couple_id = (select couple_id from public.together_moments where id = $1)`, [m.id],
      );
      assert.equal(audits.rows[0].n, 1);
    }
  });

  test('an edit racing a reveal cannot change what was revealed', async () => {
    const { a, b } = await db.createCouple();
    const m = await today(a);
    await submit(a, m.id, 'before');
    await submit(b, m.id, 'theirs');
    const results = await Promise.allSettled([reveal(b, m.id), submit(a, m.id, 'after')]);
    const final = await moment(b, m.id);
    assert.equal(final.status, 'revealed');
    // Either the edit landed first and is what was revealed, or it was refused.
    if (results[1].status === 'fulfilled') assert.equal(final.partner_answer, 'after');
    else {
      assert.match(results[1].reason.message, /already_revealed/);
      assert.equal(final.partner_answer, 'before');
    }
  });

  test('notifications say that something happened, never what was written', async () => {
    const { a, b } = await db.createCouple();
    const m = await today(a);
    await submit(a, m.id, 'SECRET-ONE');
    assert.deepEqual((await outbox(b)).map((n) => n.event), ['answered']);
    assert.deepEqual(await outbox(a), []);
    await submit(a, m.id, 'SECRET-ONE edited');
    assert.equal((await outbox(b)).length, 1, 'an edit is not announced');

    await submit(b, m.id, 'SECRET-TWO');
    assert.deepEqual((await outbox(a)).map((n) => n.event), ['ready']);
    assert.equal((await outbox(b)).length, 1);
    await reveal(a, m.id);
    assert.equal((await outbox(a)).length + (await outbox(b)).length, 2, 'revealing notifies nobody');

    const everything = JSON.stringify((await db.admin(`select * from public.notification_outbox where category = 'together'`)).rows);
    assert.equal(everything.includes('SECRET'), false);
    // What the push worker is handed carries no preview for these either.
    const claimed = await db.asService((q) => q('select * from public.claim_notifications(50)'));
    for (const item of claimed.rows.filter((r) => r.category === 'together')) {
      assert.equal(item.preview, null);
      assert.equal(JSON.stringify(item).includes('SECRET'), false);
    }
  });

  test('notification preferences are respected', async () => {
    const { a, b } = await db.createCouple();
    await db.query(b, 'update public.notification_preferences set together = false where user_id = $1', [b]);
    const m = await today(a);
    await submit(a, m.id, 'hello');
    assert.deepEqual(await outbox(b), []);
    await submit(b, m.id, 'hi');
    assert.deepEqual((await outbox(a)).map((n) => n.event), ['ready']);
    // Nobody can switch someone else's off or on.
    await db.query(a, 'update public.notification_preferences set together = false where user_id = $1', [b]);
    assert.equal((await db.admin('select together from public.notification_preferences where user_id = $1', [a])).rows[0].together, true);
  });

  test('a missed day is left behind quietly; a finished one can still be revealed', async () => {
    const { a, b } = await db.createCouple();
    const missed = await today(a);
    await submit(a, missed.id, 'only me');
    await age(missed.id, 2);
    // It is closed to both, shown to neither, and a's words stay a's.
    await db.rejects(b, 'select public.together_submit($1, $2)', [missed.id, 'late'], /moment_closed/);
    await db.rejects(a, 'select public.together_submit($1, $2)', [missed.id, 'changed'], /moment_closed/);
    await db.rejects(b, 'select public.together_reveal($1)', [missed.id], /not_ready/);
    assert.deepEqual(await history(a), []);
    assert.deepEqual(await history(b), []);
    assert.equal((await moment(b, missed.id)).partner_answer, null);

    // Today is simply a new question; nothing is owed.
    const next = await today(b);
    assert.notEqual(next.id, missed.id);
    assert.equal(next.status, 'open');
    assert.notEqual(next.question.id, missed.question.id);

    // Both answered yesterday but never opened it: still there to open.
    await submit(a, next.id, 'yes');
    await submit(b, next.id, 'and yes');
    await age(next.id, 1);
    assert.equal((await submit(a, next.id, 'yes, edited')).status, 'ready');
    const listed = await history(b);
    assert.deepEqual(listed.map((m) => m.status), ['ready']);
    assert.equal((await reveal(b, next.id)).partner_answer, 'yes, edited');
  });

  test('history lists finished moments newest first, a page at a time', async () => {
    const { a, b } = await db.createCouple();
    const ids = [];
    for (let i = 0; i < 4; i += 1) {
      const m = await today(a);
      await submit(a, m.id, `a${i}`);
      await submit(b, m.id, `b${i}`);
      if (i !== 3) await reveal(a, m.id);
      ids.unshift(m.id);
      // Push everything so far one day into the past and start a new day.
      await db.admin('update public.together_moments set day = day - 1 where couple_id = (select couple_id from public.together_moments where id = $1)', [m.id]);
    }
    const all = await history(b);
    assert.deepEqual(all.map((m) => m.id), ids);
    assert.deepEqual(all.map((m) => m.status), ['ready', 'revealed', 'revealed', 'revealed']);
    assert.equal(all[1].partner_answer, 'a2');
    assert.ok(all[0].day > all[1].day);

    const firstPage = await history(b, null, 2);
    assert.deepEqual(firstPage.map((m) => m.id), ids.slice(0, 2));
    const secondPage = await history(b, firstPage[1].day, 2);
    assert.deepEqual(secondPage.map((m) => m.id), ids.slice(2));
    assert.equal((await history(b, null, 1000)).length, 4);
  });

  test('a revealed moment is saved to memories once, by either of them, and can be unsaved', async () => {
    const { a, b, id, coupleId } = await completed();
    const fresh = await db.createCouple();
    const unrevealed = await today(fresh.a);
    await submit(fresh.a, unrevealed.id, 'x');
    await submit(fresh.b, unrevealed.id, 'y');
    await db.rejects(fresh.a, 'select public.together_save_memory($1)', [unrevealed.id], /not_revealed/);

    const [one, two] = await Promise.all([
      db.call(a, 'select public.together_save_memory($1)', [id]),
      db.call(b, 'select public.together_save_memory($1)', [id]),
    ]);
    assert.equal(one, two);
    assert.equal(await db.call(b, 'select public.together_save_memory($1)', [id]), one);
    const memories = await db.query(b, 'select id, kind, title, occurred_on, together_moment_id from public.memories where couple_id = $1', [coupleId]);
    assert.equal(memories.length, 1);
    assert.equal(memories[0].kind, 'moment');
    assert.equal(memories[0].together_moment_id, id);
    assert.equal(memories[0].title, (await moment(a, id)).question.body);
    assert.equal((await moment(a, id)).memory_id, one);
    // The memory holds the question, not the answers.
    assert.equal(JSON.stringify((await db.admin('select * from public.memories where id = $1', [one])).rows[0]).includes('from a'), false);

    await db.query(a, 'select public.together_unsave_memory($1)', [id]);
    assert.equal((await db.query(b, 'select id from public.memories where couple_id = $1', [coupleId])).length, 0);
    const after = await moment(b, id);
    assert.equal(after.memory_id, null);
    assert.equal(after.my_answer, 'from b');
    assert.equal(after.partner_answer, 'from a');
    // Removing it the ordinary way from the scrapbook works too.
    const again = await db.call(a, 'select public.together_save_memory($1)', [id]);
    await db.query(b, 'delete from public.memories where id = $1', [again]);
    assert.equal((await moment(a, id)).memory_id, null);
  });

  test('the free scrapbook limit applies to saved moments like any other memory', async () => {
    const { a, id, coupleId } = await completed();
    await db.admin(
      `insert into public.memories (couple_id, created_by, kind, title) select $1, $2, 'moment', 'filler ' || g from generate_series(1, 30) g`,
      [coupleId, a],
    );
    await db.rejects(a, 'select public.together_save_memory($1)', [id], /memory_limit_reached/);
  });

  test('unlinking closes it to both, and each person’s export holds only their own words', async () => {
    const { a, b, id } = await completed();
    await db.query(a, 'select public.leave_couple(false)');
    for (const user of [a, b]) {
      assert.deepEqual(await today(user), { status: 'unpaired' });
      assert.deepEqual(await history(user), []);
      await db.rejects(user, 'select public.together_moment($1)', [id], /moment_not_found/);
      await db.rejects(user, 'select public.together_reveal($1)', [id], /moment_not_found/);
      assert.equal((await db.query(user, 'select id from public.together_moments')).length, 0);
    }
    const exported = await db.call(a, 'select public.export_my_data()');
    assert.equal(exported.together_answers.length, 1);
    assert.equal(exported.together_answers[0].answer, 'from a');
    assert.match(exported.together_answers[0].question, /\?$/);
    assert.equal(JSON.stringify(exported).includes('from b'), false);
    // Everything the export had before is still there.
    for (const key of ['profile', 'notes', 'spaces', 'notification_preferences']) assert.ok(key in exported, key);
    await db.rejects(b, 'select app_private.export_my_data_before_together()', [], /permission denied/);
  });

  test('deleting an account removes that person’s answers and leaves their partner’s', async () => {
    const { a, b, id, coupleId } = await completed();
    await db.asService((q) => q('select public.prepare_account_deletion($1)', [a]));
    await db.admin('delete from auth.users where id = $1', [a]);
    const left = (await db.admin('select user_id, body from public.together_answers where moment_id = $1', [id])).rows;
    assert.deepEqual(left, [{ user_id: b, body: 'from b' }]);
    assert.equal((await db.call(b, 'select public.export_my_data()')).together_answers[0].answer, 'from b');
    // When the ended space is finally purged, the rest goes with it.
    await db.admin('delete from public.couple_spaces where id = $1', [coupleId]);
    assert.equal((await db.admin('select count(*)::int as n from public.together_answers where moment_id = $1', [id])).rows[0].n, 0);
    assert.equal((await db.admin('select count(*)::int as n from public.together_moments where id = $1', [id])).rows[0].n, 0);
  });

  test('the morning nudge goes once, only to couples who use this, and never as a backlog', async () => {
    const zone = (await db.admin(
      `select name from pg_catalog.pg_timezone_names where extract(hour from now() at time zone name) = 9 and name not like 'posix/%' order by name limit 1`,
    )).rows[0].name;
    const elsewhere = (await db.admin(
      `select name from pg_catalog.pg_timezone_names where extract(hour from now() at time zone name) = 15 and name not like 'posix/%' order by name limit 1`,
    )).rows[0].name;
    const announce = async () => (await db.admin('select app_private.together_announce() as n')).rows[0].n;
    const setZone = (coupleId, name) => db.admin('update public.together_settings set time_zone = $2 where couple_id = $1', [coupleId, name]);
    const news = async (user) => (await outbox(user)).filter((n) => n.event === 'new').length;

    // Uses it, and it is their morning: one each.
    const active = await completed();
    await age(active.id, 1);
    await setZone(active.coupleId, zone);
    // Opened it once, never answered: left alone.
    const idle = await db.createCouple();
    await today(idle.a);
    await setZone(idle.coupleId, zone);
    // Uses it, but it is not their morning.
    const afternoon = await completed();
    await age(afternoon.id, 1);
    await setZone(afternoon.coupleId, elsewhere);
    // Uses it, but has switched the nudge off; and their partner already answered today.
    const mixed = await completed();
    await age(mixed.id, 1);
    await setZone(mixed.coupleId, zone);
    await db.query(mixed.a, 'update public.notification_preferences set together_daily = false where user_id = $1', [mixed.a]);
    const fresh = await today(mixed.b);
    await submit(mixed.b, fresh.id, 'early bird');

    await announce();
    await announce();
    assert.equal(await news(active.a), 1);
    assert.equal(await news(active.b), 1);
    assert.equal(await news(idle.a) + await news(idle.b), 0);
    assert.equal(await news(afternoon.a) + await news(afternoon.b), 0);
    assert.equal(await news(mixed.a), 0, 'switched off');
    assert.equal(await news(mixed.b), 0, 'already answered today');

    // Someone who stopped more than a week ago is not chased.
    const lapsed = await completed();
    await age(lapsed.id, 9);
    await setZone(lapsed.coupleId, zone);
    await announce();
    assert.equal(await news(lapsed.a) + await news(lapsed.b), 0);
  });
});
