-- Developer-only, idempotent repair for the two financial history tables.
-- Run only if wamama-financial-sync-safeguards-check.sql reports ready = false.
-- It changes sync metadata, not savings or repayment amounts or statuses.
begin;

create or replace function public.pb_touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare v_table text;
begin
  foreach v_table in array array['pb_savings','pb_repayments'] loop
    execute format('alter table public.%I add column if not exists updated_at timestamptz',v_table);
    execute format('update public.%I set updated_at = coalesce(created_at,now()) where updated_at is null',v_table);
    execute format('alter table public.%I alter column updated_at set default now()',v_table);
    execute format('alter table public.%I alter column updated_at set not null',v_table);
    execute format('drop trigger if exists pb_touch_updated_at_trigger on public.%I',v_table);
    execute format('create trigger pb_touch_updated_at_trigger before update on public.%I for each row execute function public.pb_touch_updated_at()',v_table);
    execute format('create index if not exists %I on public.%I (business_id, updated_at desc)',
      v_table || '_business_updated_idx',v_table);
  end loop;
end;
$$;

commit;
