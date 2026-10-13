-- Water as a Contents item any employee can take.
-- Contents is the consumables system (stock goes down on Take, up on Restock, every move logged
-- in contents_log, low stock flagged on the dashboard). Taking from it normally needs
-- people.contents_approved; items marked open_to_all can be taken by anyone. Restock stays approved-only.
-- Safe to run more than once.

alter table public.contents add column if not exists open_to_all boolean not null default false;

insert into public.contents (item_code, item_name, category, unit_of_measure, quantity, reorder_threshold, notes, open_to_all)
select (select 'CT-' || lpad((coalesce(max(substring(item_code from '^CT-(\d+)$')::integer), 0) + 1)::text, 3, '0')
          from public.contents where item_code ~ '^CT-\d+$'),
       'Bottled Water', 'Water', 'case', 0, 5,
       'Any employee can take. Set the starting count with a Restock.', true
where not exists (select 1 from public.contents where lower(item_name) = 'bottled water');

create or replace function public.contents_adjust(p_person text, p_reason text, p_items jsonb, p_direction integer)
 returns jsonb
 language plpgsql
 security definer
as $function$
declare
  v_person public.people%rowtype;
  v_item jsonb;
  v_row public.contents%rowtype;
  v_qty int;
  v_new int;
  v_count int := 0;
  v_errors text[] := '{}';
  v_action text;
begin
  if p_direction not in (1, -1) then
    return jsonb_build_object('ok', false, 'error', 'bad_direction');
  end if;
  v_action := case when p_direction = -1 then 'Take' else 'Restock' end;

  select * into v_person from public.people
  where lower(name) = lower(btrim(p_person)) and active = true
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'unauthorized',
      'message', 'Name not recognized.');
  end if;

  -- Not approved: may only Take, and only items open to everyone (water)
  if v_person.contents_approved is not true then
    if p_direction <> -1 then
      return jsonb_build_object('ok', false, 'error', 'unauthorized',
        'message', 'You are not approved to restock supplies. Ask Jennifer or Jessica.');
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_items) e
      left join public.contents c on c.item_code = btrim(e->>'itemId')
      where c.open_to_all is not true
    ) then
      return jsonb_build_object('ok', false, 'error', 'unauthorized',
        'message', 'You can take water, but other supplies need approval. Ask Jennifer or Jessica.');
    end if;
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_qty := coalesce((v_item->>'quantity')::int, 0);
    select * into v_row from public.contents
    where item_code = btrim(v_item->>'itemId') limit 1;

    if not found then
      v_errors := v_errors || ('Item not found: ' || coalesce(v_item->>'item', '?'));
      continue;
    end if;

    if v_qty <= 0 then
      v_errors := v_errors || ('Invalid quantity for ' || v_row.item_name);
      continue;
    end if;

    v_new := greatest(0, v_row.quantity + (p_direction * v_qty));

    update public.contents
    set quantity = v_new, updated_at = now()
    where id = v_row.id;

    insert into public.contents_log
      (log_code, contents_id, item_code, item_name, person_id, person_name,
       action, quantity_change, quantity_after, notes, logged_at)
    values
      ('CL-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random()*1000)::int,
       v_row.id, v_row.item_code, v_row.item_name, v_person.id, v_person.name,
       v_action, v_qty, v_new, p_reason, now());

    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('ok', true, 'itemCount', v_count, 'errors', to_jsonb(v_errors));
end;
$function$;

-- n8n "SB Contents Lists" (sb-contents-lists), after this runs:
--   Get Contents URL select: add open_to_all
--   Build Lists contents map: add  openToAll: c.open_to_all === true
-- contents.html uses openToAll to show only water to people who are not approved.
