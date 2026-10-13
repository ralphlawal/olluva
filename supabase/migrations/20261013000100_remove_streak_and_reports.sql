-- Version 1.1's features were withdrawn before release. This removes the two
-- server pieces they added (20261011000500): the streak function, and note
-- reporting with its table. The table held no rows when this was written.
--
-- Migrations are never edited or deleted once applied, so the earlier file
-- stays and this one undoes it.

drop function if exists public.get_streak();
drop function if exists public.report_note(uuid);
drop table if exists public.note_reports;
