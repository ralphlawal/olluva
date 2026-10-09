import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { mediaPath, startDatabase } from './support/db.js';

let db;
before(async () => { db = await startDatabase(); });
after(async () => { await db?.stop(); });

async function sendNote(author, coupleId, fields = {}) {
  const id = fields.id ?? crypto.randomUUID();
  const [row] = await db.query(
    author,
    `insert into public.notes (id, couple_id, author_id, body, style, photo_path, drawing_path)
     values ($1, $2, $3, $4, $5, $6, $7) returning *`,
    [id, coupleId, fields.author ?? author, fields.body ?? 'thinking of you',
     fields.style ?? { paper: 'cream' }, fields.photo ?? null, fields.drawing ?? null],
  );
  return row;
}

const upload = (user, path, bucket = 'couple-media') =>
  db.query(user, 'insert into storage.objects (bucket_id, name, owner) values ($1, $2, $3) returning id', [bucket, path, user]);

describe('notes', () => {
  test('partners see each other\'s notes; the server sets author, version and time', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const forged = await db.query(
      a,
      `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'hi') returning author_id, version, origin`,
      [coupleId, a],
    );
    assert.deepEqual(forged[0], { author_id: a, version: 1, origin: 'direct' });
    const seen = await db.query(b, 'select body, author_id from public.notes');
    assert.deepEqual(seen, [{ body: 'hi', author_id: a }]);
  });

  test('a note cannot be written in the partner\'s name', async () => {
    const { a, b, coupleId } = await db.createCouple();
    // The trigger overwrites author_id with the caller, so impersonation is impossible.
    const note = await sendNote(a, coupleId, { author: b });
    assert.equal(note.author_id, a);
  });

  test('server-controlled columns cannot be supplied by the client', async () => {
    const { a, coupleId } = await db.createCouple();
    for (const column of ['created_at', 'seen_at', 'version', 'origin', 'deleted_at']) {
      await db.rejects(
        a, `insert into public.notes (couple_id, author_id, body, ${column}) values ($1, $2, 'x', default)`,
        [coupleId, a], /permission denied/,
      );
    }
  });

  test('another couple can neither read nor write this couple\'s notes', async () => {
    const one = await db.createCouple('Ada', 'Ben');
    const two = await db.createCouple('Cal', 'Dee');
    const note = await sendNote(one.a, one.coupleId);

    assert.deepEqual(await db.query(two.a, 'select id from public.notes where id = $1', [note.id]), []);
    await db.rejects(
      two.a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, 'intrusion')`,
      [one.coupleId, two.a], /row-level security/,
    );
    await db.rejects(two.a, 'select public.update_note($1, 1, $2, $3, null, null)', [note.id, 'x', {}], /note_not_found/);
    await db.rejects(two.a, 'select public.delete_note($1)', [note.id], /note_not_found/);
    await db.rejects(two.a, `select public.set_reaction($1, 'love')`, [note.id], /note_not_found/);
    await db.rejects(two.a, 'select public.save_note_to_memories($1)', [note.id], /note_not_found/);
    await db.query(two.a, 'select public.mark_note_seen($1)', [note.id]);
    const { rows } = await db.admin('select seen_at, body from public.notes where id = $1', [note.id]);
    assert.deepEqual(rows[0], { seen_at: null, body: 'thinking of you' });
  });

  test('notes cannot be updated or deleted with direct table writes', async () => {
    const { a, coupleId } = await db.createCouple();
    await sendNote(a, coupleId);
    await db.rejects(a, `update public.notes set body = 'edited'`, [], /permission denied/);
    await db.rejects(a, 'delete from public.notes', [], /permission denied/);
  });

  test('a retried send with the same id does not create a second note', async () => {
    const { a, coupleId } = await db.createCouple();
    const id = crypto.randomUUID();
    await sendNote(a, coupleId, { id });
    await db.rejects(
      a, `insert into public.notes (id, couple_id, author_id, body) values ($1, $2, $3, 'again')`,
      [id, coupleId, a], /duplicate key/,
    );
    assert.equal((await db.query(a, 'select id from public.notes')).length, 1);
  });

  test('only the author can edit, and a stale edit is rejected rather than overwriting', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId);

    await db.rejects(b, 'select public.update_note($1, 1, $2, $3, null, null)', [note.id, 'hijack', {}], /not_note_author/);

    const [edited] = await db.query(a, 'select * from public.update_note($1, 1, $2, $3, null, null)', [note.id, 'first edit', {}]);
    assert.equal(edited.version, 2);
    // A second device still holding version 1 must not clobber the first edit.
    await db.rejects(a, 'select public.update_note($1, 1, $2, $3, null, null)', [note.id, 'stale edit', {}], /version_conflict/);
    const [current] = await db.query(a, 'select body, version from public.notes where id = $1', [note.id]);
    assert.deepEqual(current, { body: 'first edit', version: 2 });
  });

  test('two simultaneous edits from the same version: exactly one wins', async () => {
    const { a, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId);
    const outcomes = await Promise.allSettled(['one', 'two', 'three'].map((body) =>
      db.query(a, 'select public.update_note($1, 1, $2, $3, null, null)', [note.id, body, {}])));
    assert.equal(outcomes.filter((o) => o.status === 'fulfilled').length, 1);
    for (const lost of outcomes.filter((o) => o.status === 'rejected')) {
      assert.match(lost.reason.message, /version_conflict/);
    }
  });

  test('deleting erases the content and leaves a tombstone; only the author can delete', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId, { body: 'private words' });
    await db.rejects(b, 'select public.delete_note($1)', [note.id], /not_note_author/);
    await db.query(a, 'select public.delete_note($1)', [note.id]);
    const [tombstone] = await db.query(b, 'select body, style, deleted_at is not null as deleted from public.notes where id = $1', [note.id]);
    assert.deepEqual(tombstone, { body: '', style: {}, deleted: true });
    await db.rejects(a, 'select public.update_note($1, 2, $2, $3, null, null)', [note.id, 'undelete', {}], /note_not_found/);
  });

  test('validation: empty notes, over-long text and oversized styles are refused', async () => {
    const { a, coupleId } = await db.createCouple();
    await db.rejects(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, '   ')`, [coupleId, a], /notes_has_content/);
    await db.rejects(a, `insert into public.notes (couple_id, author_id, body) values ($1, $2, $3)`, [coupleId, a, 'x'.repeat(281)], /notes_body_check/);
    // Random content so it cannot be compressed under the limit.
    const big = { blob: Array.from({ length: 600 }, () => crypto.randomUUID()).join('') };
    await db.rejects(a, `insert into public.notes (couple_id, author_id, body, style) values ($1, $2, 'x', $3)`, [coupleId, a, big], /notes_style_check/);
  });

  test('seen is set once, by the recipient only', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId);
    await db.query(a, 'select public.mark_note_seen($1)', [note.id]);
    assert.equal((await db.query(a, 'select seen_at from public.notes'))[0].seen_at, null);
    await db.query(b, 'select public.mark_note_seen($1)', [note.id]);
    const first = (await db.query(a, 'select seen_at from public.notes'))[0].seen_at;
    assert.ok(first);
    await db.query(b, 'select public.mark_note_seen($1)', [note.id]);
    assert.deepEqual((await db.query(a, 'select seen_at from public.notes'))[0].seen_at, first);
  });

  test('reactions: one per person, on the partner\'s notes only', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId);
    await db.rejects(a, `select public.set_reaction($1, 'love')`, [note.id], /cannot_react_to_own_note/);
    await db.query(b, `select public.set_reaction($1, 'love')`, [note.id]);
    await db.query(b, `select public.set_reaction($1, 'laugh')`, [note.id]);
    assert.deepEqual(await db.query(a, 'select kind, user_id from public.note_reactions'), [{ kind: 'laugh', user_id: b }]);
    await db.rejects(b, `select public.set_reaction($1, 'thumbsdown')`, [note.id], /note_reactions_kind_check/);
    await db.rejects(b, `insert into public.note_reactions (note_id, user_id, couple_id, kind) values ($1, $2, $3, 'love')`, [note.id, b, coupleId], /permission denied/);
    await db.query(b, 'select public.set_reaction($1, null)', [note.id]);
    assert.deepEqual(await db.query(a, 'select kind from public.note_reactions'), []);
  });
});

describe('private media', () => {
  test('a member can upload into and read from their couple folder only', async () => {
    const one = await db.createCouple();
    const two = await db.createCouple('Cal', 'Dee');
    const path = mediaPath(one.coupleId);
    await upload(one.a, path);

    assert.equal((await db.query(one.b, 'select name from storage.objects where name = $1', [path])).length, 1);
    assert.deepEqual(await db.query(two.a, 'select name from storage.objects where name = $1', [path]), []);
    await assert.rejects(() => upload(two.a, mediaPath(one.coupleId)), /row-level security/);
  });

  test('malformed and traversal-style object names fail closed', async () => {
    const { a, coupleId } = await db.createCouple();
    const other = await db.createCouple('Cal', 'Dee');
    for (const name of [
      `couples/${coupleId}/../${other.coupleId}/${crypto.randomUUID()}.jpg`,
      `couples/${coupleId}/nested/${crypto.randomUUID()}.jpg`,
      `couples/${coupleId}/${crypto.randomUUID()}.html`,
      `couples/not-a-uuid/${crypto.randomUUID()}.jpg`,
      `${coupleId}/${crypto.randomUUID()}.jpg`,
      `couples/${coupleId}/`,
    ]) {
      await assert.rejects(() => upload(a, name), /row-level security/, `accepted ${name}`);
    }
  });

  test('uploaded media is write-once: no overwrite, no client delete', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const path = mediaPath(coupleId);
    await upload(a, path);
    for (const user of [a, b]) {
      const updated = await db.as(user, (q) => q(`update storage.objects set metadata = '{"x":1}' where name = $1`, [path]));
      assert.equal(updated.rowCount, 0);
      const deleted = await db.as(user, (q) => q('delete from storage.objects where name = $1', [path]));
      assert.equal(deleted.rowCount, 0);
    }
  });

  test('a note can only reference media inside its own couple folder', async () => {
    const one = await db.createCouple();
    const two = await db.createCouple('Cal', 'Dee');
    await assert.rejects(() => sendNote(one.a, one.coupleId, { photo: mediaPath(two.coupleId) }), /notes_photo_path_scoped/);
    await assert.rejects(() => sendNote(one.a, one.coupleId, { photo: 'couples/../etc/passwd' }), /notes_photo_path_scoped/);
    const ok = await sendNote(one.a, one.coupleId, { body: '', photo: mediaPath(one.coupleId), drawing: mediaPath(one.coupleId, 'png') });
    assert.ok(ok.photo_path);
  });

  test('access to media ends the moment the couple unlinks', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const path = mediaPath(coupleId);
    await upload(a, path);
    await db.query(a, 'select public.leave_couple()');
    for (const user of [a, b]) {
      assert.deepEqual(await db.query(user, 'select name from storage.objects where name = $1', [path]), []);
      await assert.rejects(() => upload(user, mediaPath(coupleId)), /row-level security/);
    }
  });

  test('avatars: own folder only for writes; readable by self and partner', async () => {
    const { a, b } = await db.createCouple();
    const stranger = await db.createUser('Eve');
    await upload(a, `${a}/avatar.jpg`, 'avatars');
    await assert.rejects(() => upload(stranger, `${a}/avatar.jpg`, 'avatars'), /row-level security|duplicate key/);
    await assert.rejects(() => upload(stranger, `${b}/avatar.jpg`, 'avatars'), /row-level security/);
    assert.equal((await db.query(b, `select name from storage.objects where bucket_id = 'avatars'`)).length, 1);
    assert.deepEqual(await db.query(stranger, `select name from storage.objects where bucket_id = 'avatars'`), []);

    await db.query(a, `update public.profiles set avatar_path = $1 where id = $2`, [`${a}/avatar.jpg`, a]);
    await db.rejects(a, `update public.profiles set avatar_path = $1 where id = $2`, [`${b}/avatar.jpg`, a], /row-level security/);
  });

  test('media is queued for purge only once nothing references it', async () => {
    const { a, coupleId } = await db.createCouple();
    const photo = mediaPath(coupleId);
    const note = await sendNote(a, coupleId, { photo });
    await db.query(a, 'select public.save_note_to_memories($1)', [note.id]);

    await db.query(a, 'select public.delete_note($1)', [note.id]);
    const queued = async () => (await db.admin('select path from public.storage_purge_queue where path = $1', [photo])).rows.length;
    assert.equal(await queued(), 0, 'still used by the memory');

    await db.query(a, 'delete from public.memories');
    assert.equal(await queued(), 1);
    const claimed = await db.asService((q) => q('select * from public.claim_storage_purges(10)'));
    assert.ok(claimed.rows.some((r) => r.path === photo));
  });
});

describe('memories', () => {
  test('saving a note copies it, once, and the memory outlives the note', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const note = await sendNote(a, coupleId, { body: 'keep this' });
    const first = await db.call(b, 'select public.save_note_to_memories($1, $2)', [note.id, 'our first']);
    const second = await db.call(a, 'select public.save_note_to_memories($1)', [note.id]);
    assert.equal(first, second);

    await db.query(a, 'select public.delete_note($1)', [note.id]);
    const [memory] = await db.query(b, 'select kind, body, caption from public.memories');
    assert.deepEqual(memory, { kind: 'note', body: 'keep this', caption: 'our first' });
  });

  test('a memory cannot be forged as a saved note or planted in another couple', async () => {
    const one = await db.createCouple();
    const two = await db.createCouple('Cal', 'Dee');
    await db.rejects(
      one.a, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'note', 'fake')`,
      [one.coupleId, one.a], /row-level security/,
    );
    await db.rejects(
      one.a, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'moment', 'x')`,
      [two.coupleId, one.a], /row-level security/,
    );
    await db.query(one.a, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'moment', 'First trip')`, [one.coupleId, one.a]);
    assert.deepEqual(await db.query(two.a, 'select id from public.memories'), []);
    const cross = await db.as(two.a, (q) => q('delete from public.memories'));
    assert.equal(cross.rowCount, 0);
  });

  test('the free limit is enforced by the server and lifted by either partner\'s subscription', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.admin(
      `insert into public.memories (couple_id, created_by, kind, title)
       select $1, $2, 'moment', 'm' || g from generate_series(1, 30) g`, [coupleId, a],
    );
    const add = (user) => db.query(user, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'moment', 'one more')`, [coupleId, user]);
    await assert.rejects(() => add(a), /memory_limit_reached/);
    await db.makePremium(b);
    await add(a);
  });

  test('simultaneous saves cannot slip past the limit', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.admin(
      `insert into public.memories (couple_id, created_by, kind, title)
       select $1, $2, 'moment', 'm' || g from generate_series(1, 29) g`, [coupleId, a],
    );
    const attempts = await Promise.allSettled([a, b, a, b].map((user) =>
      db.query(user, `insert into public.memories (couple_id, created_by, kind, title) values ($1, $2, 'moment', 'race')`, [coupleId, user])));
    assert.equal(attempts.filter((r) => r.status === 'fulfilled').length, 1);
    assert.equal((await db.admin('select count(*)::int as n from public.memories where couple_id = $1', [coupleId])).rows[0].n, 30);
  });
});

describe('important dates', () => {
  const addDate = (user, coupleId, fields = {}) => db.query(
    user,
    `insert into public.important_dates (couple_id, created_by, title, kind, starts_on, recurrence, visibility, remind_days_before)
     values ($1, $2, $3, $4, $5, $6, $7, $8) returning id`,
    [coupleId, user, fields.title ?? 'Anniversary', fields.kind ?? 'anniversary', fields.starts_on ?? '2020-06-14',
     fields.recurrence ?? 'yearly', fields.visibility ?? 'shared', fields.remind ?? [0, 7]],
  );

  test('shared dates are visible to both; private dates only to their owner', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await addDate(a, coupleId, { title: 'Anniversary' });
    const [secret] = await addDate(a, coupleId, { title: 'Proposal plan', visibility: 'private' });
    assert.deepEqual((await db.query(b, 'select title from public.important_dates')).map((r) => r.title), ['Anniversary']);
    const tampered = await db.as(b, (q) => q(`update public.important_dates set title = 'found it' where id = $1`, [secret.id]));
    assert.equal(tampered.rowCount, 0);
    const removed = await db.as(b, (q) => q('delete from public.important_dates where id = $1', [secret.id]));
    assert.equal(removed.rowCount, 0);
  });

  test('a partner can edit a shared date but cannot change who sees it or who owns it', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const [date] = await addDate(a, coupleId);
    await db.query(b, `update public.important_dates set title = 'Our day' where id = $1`, [date.id]);
    await db.rejects(b, `update public.important_dates set visibility = 'private' where id = $1`, [date.id], /not_date_owner/);
    await db.rejects(b, `update public.important_dates set created_by = $2 where id = $1`, [date.id, b], /permission denied/);
  });

  test('other couples see nothing; reminder offsets are validated', async () => {
    const one = await db.createCouple();
    const two = await db.createCouple('Cal', 'Dee');
    await addDate(one.a, one.coupleId);
    assert.deepEqual(await db.query(two.a, 'select id from public.important_dates'), []);
    await assert.rejects(() => addDate(two.a, one.coupleId), /row-level security/);
    await assert.rejects(() => addDate(one.a, one.coupleId, { remind: [2] }), /remind_days_before_check/);
  });

  test('next_occurrence handles recurrence, leap days and month ends', async () => {
    const next = async (start, recurrence, today) =>
      (await db.admin(`select app_private.next_occurrence($1::date, $2, $3::date)::text as d`, [start, recurrence, today])).rows[0].d;
    assert.equal(await next('2020-06-14', 'yearly', '2026-06-14'), '2026-06-14');
    assert.equal(await next('2020-06-14', 'yearly', '2026-06-15'), '2027-06-14');
    assert.equal(await next('2020-02-29', 'yearly', '2026-01-01'), '2026-02-28');
    assert.equal(await next('2020-02-29', 'yearly', '2028-02-01'), '2028-02-29');
    assert.equal(await next('2026-01-31', 'monthly', '2026-02-10'), '2026-02-28');
    assert.equal(await next('2026-01-31', 'monthly', '2026-03-01'), '2026-03-31');
    assert.equal(await next('2030-05-01', 'yearly', '2026-01-01'), '2030-05-01');
    assert.equal(await next('2020-05-01', 'none', '2026-01-01'), null);
  });

  test('reminders are queued once per person per occurrence, honouring visibility and preferences', async () => {
    const { a, b, coupleId } = await db.createCouple();
    // 14:00 UTC is past 09:00 in both zones used here.
    await db.admin(`update public.profiles set time_zone = 'Europe/London' where id = any($1)`, [[a, b]]);
    const hourInLondon = (await db.admin(`select extract(hour from now() at time zone 'Europe/London')::int as h`)).rows[0].h;
    const today = (await db.admin(`select (now() at time zone 'Europe/London')::date::text as d`)).rows[0].d;
    await addDate(a, coupleId, { title: 'Today', starts_on: today, recurrence: 'none', remind: [0] });
    await addDate(a, coupleId, { title: 'Secret', starts_on: today, recurrence: 'none', remind: [0], visibility: 'private' });

    await db.admin('select app_private.enqueue_date_reminders()');
    await db.admin('select app_private.enqueue_date_reminders()');
    const { rows } = await db.admin(
      `select user_id, count(*)::int as n from public.notification_outbox
       where category = 'important_date' and user_id = any($1) group by user_id`, [[a, b]],
    );
    const byUser = Object.fromEntries(rows.map((r) => [r.user_id, r.n]));
    if (hourInLondon >= 9) {
      assert.equal(byUser[a], 2, 'owner is reminded of the shared and the private date');
      assert.equal(byUser[b], 1, 'partner is reminded of the shared date only, once');
    } else {
      assert.deepEqual(byUser, {}, 'nothing is sent before 09:00 local time');
    }
  });
});

describe('scheduled messages', () => {
  const schedule = (user, coupleId, when = `now() + interval '1 hour'`, body = 'surprise') => db.query(
    user,
    `insert into public.scheduled_messages (couple_id, author_id, body, deliver_at, time_zone)
     values ($1, $2, $3, ${when}, 'Europe/Lisbon') returning *`,
    [coupleId, user, body],
  );
  const makeDue = (id) => db.admin(`update public.scheduled_messages set deliver_at = now() - interval '1 second' where id = $1`, [id]);
  const deliver = async () => (await db.admin('select app_private.deliver_due_scheduled_messages() as n')).rows[0].n;

  test('a surprise is invisible to the partner until it is delivered', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const [message] = await schedule(a, coupleId);
    assert.deepEqual(await db.query(b, 'select id from public.scheduled_messages'), []);
    await db.rejects(b, 'select public.cancel_scheduled_message($1)', [message.id], /scheduled_not_found/);

    await makeDue(message.id);
    assert.equal(await deliver(), 1);
    const [note] = await db.query(b, 'select id, body, origin, author_id from public.notes');
    assert.deepEqual(note, { id: message.id, body: 'surprise', origin: 'scheduled', author_id: a });
    const [status] = await db.query(a, 'select status, delivered_note_id from public.scheduled_messages');
    assert.deepEqual(status, { status: 'delivered', delivered_note_id: message.id });
  });

  test('delivery times are validated on the server', async () => {
    const { a, coupleId } = await db.createCouple();
    await assert.rejects(() => schedule(a, coupleId, `now() - interval '1 hour'`), /deliver_at_too_soon/);
    await assert.rejects(() => schedule(a, coupleId, `now() + interval '3 years'`), /deliver_at_too_far/);
    await db.rejects(
      a, `insert into public.scheduled_messages (couple_id, author_id, body, deliver_at, time_zone) values ($1, $2, 'x', now() + interval '1 hour', 'Mars/Olympus')`,
      [coupleId, a], /invalid_time_zone/,
    );
  });

  test('overlapping workers and replays never deliver twice', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await db.makePremium(a);
    const ids = [];
    for (let i = 0; i < 6; i += 1) {
      ids.push((await schedule(a, coupleId, `now() + interval '1 hour'`, `surprise ${i}`))[0].id);
    }
    await db.admin(`update public.scheduled_messages set deliver_at = now() - interval '1 second' where id = any($1)`, [ids]);

    const counts = await Promise.all(Array.from({ length: 6 }, () => deliver()));
    assert.equal(counts.reduce((sum, n) => sum + n, 0), 6);
    assert.equal(await deliver(), 0);

    // Force a replay of rows that were already delivered: still one note each.
    await db.admin(`update public.scheduled_messages set status = 'pending' where id = any($1)`, [ids]);
    await deliver();
    assert.equal((await db.query(b, 'select id from public.notes')).length, 6);
    const { rows } = await db.admin(
      `select count(*)::int as n from public.notification_outbox where category = 'surprise' and user_id = $1`, [b],
    );
    assert.equal(rows[0].n, 6, 'one notification per surprise');
  });

  test('a cancelled message is never delivered, and cancel races delivery safely', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const [message] = await schedule(a, coupleId);
    await db.query(a, 'select public.cancel_scheduled_message($1)', [message.id]);
    await makeDue(message.id);
    assert.equal(await deliver(), 0);
    assert.deepEqual(await db.query(b, 'select id from public.notes'), []);

    for (let round = 0; round < 5; round += 1) {
      const [racing] = await schedule(a, coupleId);
      await makeDue(racing.id);
      const [cancelled] = await Promise.allSettled([
        db.query(a, 'select public.cancel_scheduled_message($1)', [racing.id]),
        deliver(),
      ]);
      const { rows } = await db.admin('select status from public.scheduled_messages where id = $1', [racing.id]);
      const delivered = (await db.admin('select 1 from public.notes where id = $1', [racing.id])).rows.length;
      if (rows[0].status === 'cancelled') {
        assert.equal(delivered, 0);
      } else {
        assert.equal(rows[0].status, 'delivered');
        assert.equal(delivered, 1);
        assert.equal(cancelled.status, 'rejected');
      }
    }
  });

  test('edits use version checks and are refused after delivery', async () => {
    const { a, coupleId } = await db.createCouple();
    const [message] = await schedule(a, coupleId);
    const args = [message.id, 'edited', {}, null, null];
    const sql = (version) => `select * from public.update_scheduled_message($1, ${version}, $2, $3, $4, $5, now() + interval '2 hours', 'UTC')`;
    const [edited] = await db.query(a, sql(1), args);
    assert.equal(edited.version, 2);
    await db.rejects(a, sql(1), args, /version_conflict/);
    await makeDue(message.id);
    await deliver();
    await db.rejects(a, sql(2), args, /scheduled_not_pending/);
    await db.rejects(a, 'select public.cancel_scheduled_message($1)', [message.id], /scheduled_not_pending/);
  });

  test('nothing is delivered into a space that has been unlinked', async () => {
    const { a, b, coupleId } = await db.createCouple();
    const [message] = await schedule(a, coupleId);
    await db.query(b, 'select public.leave_couple()');
    await makeDue(message.id);
    assert.equal(await deliver(), 0);
    const { rows } = await db.admin('select status, failure_reason from public.scheduled_messages where id = $1', [message.id]);
    assert.deepEqual(rows[0], { status: 'failed', failure_reason: 'not_paired' });
    assert.equal((await db.admin('select 1 from public.notes where id = $1', [message.id])).rows.length, 0);
  });

  test('the free tier allows one pending surprise; premium lifts it', async () => {
    const { a, b, coupleId } = await db.createCouple();
    await schedule(a, coupleId);
    await assert.rejects(() => schedule(a, coupleId), /scheduled_limit_reached/);
    await schedule(b, coupleId); // the limit is per author
    await db.makePremium(b);
    await schedule(a, coupleId);
  });

  test('status and delivery fields cannot be set by the client', async () => {
    const { a, coupleId } = await db.createCouple();
    await db.rejects(
      a, `insert into public.scheduled_messages (couple_id, author_id, body, deliver_at, status) values ($1, $2, 'x', now() + interval '1 hour', 'delivered')`,
      [coupleId, a], /permission denied/,
    );
    await db.rejects(a, `update public.scheduled_messages set status = 'pending'`, [], /permission denied/);
    await db.rejects(a, 'select app_private.deliver_due_scheduled_messages()', [], /permission denied/);
  });
});
