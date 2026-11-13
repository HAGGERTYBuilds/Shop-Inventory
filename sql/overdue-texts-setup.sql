-- Overdue text reminders (Ahren's dashboard -> Twilio -> YES/NO replies)
-- Run once in Supabase "HCI Inventory" SQL editor. Safe to re-run.
-- Phone numbers live in their own table with no public access, because the
-- people table is readable by the shop pages.

create table if not exists public.people_phones (
  person_id  uuid primary key references public.people(id) on delete cascade,
  phone_e164 text not null,
  updated_by text,
  updated_at timestamptz not null default now()
);
create unique index if not exists people_phones_phone_idx on public.people_phones (phone_e164);
alter table public.people_phones enable row level security;
revoke all on public.people_phones from anon, authenticated;

create table if not exists public.overdue_texts (
  id           uuid primary key default gen_random_uuid(),
  checkout_id  uuid references public.checkouts(id) on delete cascade,
  person_id    uuid references public.people(id) on delete set null,
  phone_e164   text not null,
  kind         text not null check (kind in ('ask','reply','eod_reminder','inbound')),
  body         text not null,
  status       text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled','received')),
  send_at      timestamptz not null default now(),
  sent_at      timestamptz,
  provider_sid text,
  error        text,
  answer       text check (answer in ('yes','no')),   -- on 'ask' rows, once the person replies
  answered_at  timestamptz,
  sent_by      text,
  created_at   timestamptz not null default now()
);
create index if not exists overdue_texts_queue_idx on public.overdue_texts (status, send_at);
create index if not exists overdue_texts_phone_idx on public.overdue_texts (phone_e164, kind, created_at desc);
alter table public.overdue_texts enable row level security;
revoke all on public.overdue_texts from anon, authenticated;

-- "(209) 555-1234", "209.555.1234", "+1 209 555 1234" -> "+12095551234"; null if not a US number
create or replace function public.to_e164(p text) returns text language sql immutable as $$
  select case
    when d ~ '^1[2-9][0-9]{9}$' then '+' || d
    when d ~ '^[2-9][0-9]{9}$' then '+1' || d
    else null end
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') as d) x;
$$;

-- Shop "today" is Pacific time. Due dates are stored as midnight UTC of the due day.
create or replace function public.shop_today() returns date language sql stable as $$
  select (now() at time zone 'America/Los_Angeles')::date;
$$;

-- Dashboard: latest text per overdue checkout + whether we have a number for each person.
create or replace function public.admin_overdue_text_status(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check_key(p_token) then return jsonb_build_object('ok', false, 'error', 'unauthorized'); end if;
  return jsonb_build_object('ok', true,
    'texts', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
      select distinct on (c.checkout_code) c.checkout_code as "code", o.created_at as "sentAt", o.status, o.answer, o.answered_at as "answeredAt", o.error, o.sent_by as "sentBy"
        from public.overdue_texts o join public.checkouts c on c.id = o.checkout_id
       where o.kind = 'ask' and c.checked_out
       order by c.checkout_code, o.created_at desc) t),
    'phones', (select coalesce(jsonb_object_agg(p.name, right(pp.phone_e164, 4)), '{}'::jsonb)
                 from public.people_phones pp join public.people p on p.id = pp.person_id));
end; $$;

-- Dashboard: Ahren taps "Text" on an overdue item. Queues the text; n8n sends it.
create or replace function public.admin_send_overdue_text(p_token text, p_editor text, p_checkout_code text, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_c public.checkouts%rowtype; v_p public.people%rowtype; v_phone text; v_first text; v_body text; v_due text;
begin
  if not public.admin_check_key(p_token) then return jsonb_build_object('ok', false, 'error', 'unauthorized', 'message', 'Access key not accepted.'); end if;
  select * into v_c from public.checkouts where checkout_code = btrim(p_checkout_code) limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found', 'message', 'Checkout not found.'); end if;
  if v_c.checked_out is not true then return jsonb_build_object('ok', false, 'error', 'returned', 'message', 'That item was already returned.'); end if;
  select * into v_p from public.people where id = v_c.person_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_person', 'message', 'Nobody is on this checkout.'); end if;

  if nullif(btrim(coalesce(p_phone,'')), '') is not null then
    v_phone := public.to_e164(p_phone);
    if v_phone is null then return jsonb_build_object('ok', false, 'error', 'bad_phone', 'message', 'That does not look like a 10-digit US cell number.'); end if;
    if exists (select 1 from public.people_phones where phone_e164 = v_phone and person_id <> v_p.id) then
      return jsonb_build_object('ok', false, 'error', 'phone_taken', 'message', 'That number is already saved for someone else.');
    end if;
    insert into public.people_phones (person_id, phone_e164, updated_by) values (v_p.id, v_phone, btrim(p_editor))
      on conflict (person_id) do update set phone_e164 = excluded.phone_e164, updated_by = excluded.updated_by, updated_at = now();
  else
    select phone_e164 into v_phone from public.people_phones where person_id = v_p.id;
    if v_phone is null then return jsonb_build_object('ok', false, 'error', 'no_phone', 'message', 'Add a cell number for ' || v_p.name || ' first.'); end if;
  end if;

  if exists (select 1 from public.overdue_texts where checkout_id = v_c.id and kind = 'ask' and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'error', 'too_soon', 'message', 'A text for this item went out in the last 10 minutes.');
  end if;

  v_first := split_part(coalesce(nullif(btrim(v_p.full_name), ''), v_p.name), ' ', 1);
  v_due := to_char(v_c.due_back_at at time zone 'UTC', 'FMMon FMDD');
  v_body := 'HAGGERTY Shop: Hi ' || v_first || ', the ' || v_c.item_name || ' you checked out was due back ' || v_due
         || '. Do you need more time? Reply YES for 5 more days, or NO if you will check it back in today. Reply STOP to opt out.';
  insert into public.overdue_texts (checkout_id, person_id, phone_e164, kind, body, sent_by)
    values (v_c.id, v_p.id, v_phone, 'ask', v_body, btrim(coalesce(p_editor, '')));
  return jsonb_build_object('ok', true, 'person', v_p.name, 'phoneLast4', right(v_phone, 4), 'body', v_body);
end; $$;

-- n8n sender: claim queued texts that are due. Cancels end-of-day reminders for items already returned.
create or replace function public.claim_overdue_texts()
returns table (id uuid, phone_e164 text, body text) language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  update public.overdue_texts o set status = 'cancelled', error = 'item already returned'
    from public.checkouts c
   where c.id = o.checkout_id and o.status = 'queued' and o.send_at <= now() and o.kind = 'eod_reminder' and c.checked_out is not true;
  return query
    update public.overdue_texts o set status = 'sending'
     where o.id in (select q.id from public.overdue_texts q where q.status = 'queued' and q.send_at <= now() order by q.send_at limit 50 for update skip locked)
    returning o.id, o.phone_e164, o.body;
end; $$;

create or replace function public.record_overdue_text_result(p_id uuid, p_sid text, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.overdue_texts
     set status = case when nullif(p_error, '') is null then 'sent' else 'failed' end,
         sent_at = case when nullif(p_error, '') is null then now() end,
         provider_sid = nullif(p_sid, ''), error = nullif(p_error, '')
   where id = p_id;
$$;

-- n8n inbound: a text came in from p_from. Returns the reply to send back (empty = say nothing).
create or replace function public.handle_overdue_text_reply(p_from text, p_body text, p_sid text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_phone text := public.to_e164(p_from);
  v_txt text := lower(btrim(regexp_replace(coalesce(p_body,''), '[^a-zA-Z ]', '', 'g')));
  v_ans text; v_pid uuid; v_first text; v_items text; v_new_due timestamptz; v_reply text; v_eod timestamptz; r record; n int := 0;
begin
  if v_phone is null then return jsonb_build_object('reply', ''); end if;
  select pp.person_id, split_part(coalesce(nullif(btrim(p.full_name), ''), p.name), ' ', 1) into v_pid, v_first
    from public.people_phones pp join public.people p on p.id = pp.person_id where pp.phone_e164 = v_phone;
  insert into public.overdue_texts (person_id, phone_e164, kind, body, status, provider_sid)
    values (v_pid, v_phone, 'inbound', left(coalesce(p_body,''), 1000), 'received', p_sid);
  if v_pid is null then return jsonb_build_object('reply', ''); end if;

  v_ans := case when v_txt ~ '^(yes|y|yeah|yep|yup|ya|yea)( |$)' then 'yes'
                when v_txt ~ '^(no|n|nope|nah)( |$)' then 'no' end;

  -- Open questions: asks to this number in the last 3 days, not answered, item still out.
  if not exists (select 1 from public.overdue_texts o join public.checkouts c on c.id = o.checkout_id
                  where o.phone_e164 = v_phone and o.kind = 'ask' and o.status = 'sent' and o.answer is null
                    and o.created_at > now() - interval '3 days' and c.checked_out) then
    return jsonb_build_object('reply', '');
  end if;
  if v_ans is null then
    return jsonb_build_object('reply', 'HAGGERTY Shop: Please reply YES if you need 5 more days, or NO if you will check it back in today.');
  end if;

  v_new_due := (public.shop_today() + 5)::timestamp at time zone 'UTC';
  v_eod := ((public.shop_today())::timestamp + time '15:30') at time zone 'America/Los_Angeles';

  for r in select distinct on (c.id) o.id as ask_id, c.id as cid, c.checkout_code, c.item_name, c.due_back_at
             from public.overdue_texts o join public.checkouts c on c.id = o.checkout_id
            where o.phone_e164 = v_phone and o.kind = 'ask' and o.status = 'sent' and o.answer is null
              and o.created_at > now() - interval '3 days' and c.checked_out
            order by c.id, o.created_at desc loop
    n := n + 1;
    v_items := coalesce(v_items || ', ', '') || r.item_name;
    update public.overdue_texts set answer = v_ans, answered_at = now()
     where checkout_id = r.cid and kind = 'ask' and answer is null;
    if v_ans = 'yes' then
      update public.checkouts set due_back_at = v_new_due, updated_at = now() where id = r.cid;
      insert into public.checkout_adjustments (checkout_code, action, editor, changes, reason)
        values (r.checkout_code, 'update', 'Text reply (' || v_first || ')',
                jsonb_build_object('due_back_at', jsonb_build_object('from', r.due_back_at, 'to', v_new_due)), 'Replied YES to overdue text: 5 more days');
    elsif now() < v_eod - interval '15 minutes' then
      insert into public.overdue_texts (checkout_id, person_id, phone_e164, kind, body, send_at, sent_by)
        values (r.cid, v_pid, v_phone, 'eod_reminder',
                'HAGGERTY Shop: Reminder to check the ' || r.item_name || ' back in at the shop before you leave today. Use the Return page in the shop app when you drop it off.',
                v_eod, 'auto');
    end if;
  end loop;

  if v_ans = 'yes' then
    v_reply := 'HAGGERTY Shop: Thanks ' || v_first || '. ' || v_items || ' ' || case when n > 1 then 'are' else 'is' end
            || ' now due back ' || to_char(v_new_due at time zone 'UTC', 'FMDay, FMMon FMDD') || '.';
  else
    v_reply := 'HAGGERTY Shop: Thanks ' || v_first || '. Please check the ' || v_items || ' back in at the shop by the end of the day today.';
  end if;
  return jsonb_build_object('reply', v_reply, 'answer', v_ans, 'items', n);
end; $$;

revoke all on function public.claim_overdue_texts() from public, anon, authenticated;
revoke all on function public.record_overdue_text_result(uuid, text, text) from public, anon, authenticated;
revoke all on function public.handle_overdue_text_reply(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_overdue_text_status(text) to anon, authenticated;
grant execute on function public.admin_send_overdue_text(text, text, text, text) to anon, authenticated;
grant execute on function public.claim_overdue_texts() to service_role;
grant execute on function public.record_overdue_text_result(uuid, text, text) to service_role;
grant execute on function public.handle_overdue_text_reply(text, text, text) to service_role;
grant all on public.people_phones, public.overdue_texts to service_role;
