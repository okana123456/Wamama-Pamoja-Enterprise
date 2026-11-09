-- Grant supervisors scoped product deposit transfers using current group ownership.
begin;

create or replace function wamama_deposit_private.supervisor_can_transfer_for_member(
  p_business_id text, p_staff_id text, p_team text, p_member_id text
)
returns boolean language sql stable security invoker set search_path = ''
as $$
  select exists (
    select 1
    from public.pb_members m
    join public.pb_groups g on g.id::text = m.group_id::text
      and g.business_id::text = m.business_id::text
    where m.id::text = p_member_id and m.business_id::text = p_business_id
      and (
        g.officer_id::text = p_staff_id
        or (
          nullif(lower(trim(p_team)), '') is not null
          and exists (
            select 1 from public.pb_staff owner
            where owner.id::text = g.officer_id::text
              and owner.business_id::text = p_business_id
              and lower(coalesce(owner.status::text, 'active')) = 'active'
              and lower(trim(owner.team_name::text)) = lower(trim(p_team))
          )
        )
      )
  );
$$;
revoke all on function wamama_deposit_private.supervisor_can_transfer_for_member(text,text,text,text)
  from public,anon,authenticated;

create or replace function public.pb_supervisor_product_deposits()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare actor public.pb_staff%rowtype;
begin
  select s.* into actor from public.pb_staff s
  where s.auth_user_id = auth.uid() and lower(coalesce(s.status::text, 'active')) = 'active'
  limit 1;
  if not found or lower(coalesce(actor.role::text,'')) <> 'supervisor' then
    raise exception 'An active supervisor session is required.';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', ep.id, 'member_id', ep.member_id, 'group_id', m.group_id,
      'payment_date', ep.payment_date, 'original_payment_amount', ep.original_payment_amount,
      'excess_amount', ep.excess_amount, 'released_amount', ep.released_amount,
      'amount_applied_to_loan', ep.amount_applied_to_loan, 'source', ep.source, 'status', ep.status
    ) order by ep.payment_date desc, ep.id), '[]'::jsonb)
    from public.pb_excess_payments ep
    join public.pb_members m on m.id::text = ep.member_id::text
      and m.business_id::text = actor.business_id::text
    where ep.business_id::text = actor.business_id::text
      and ep.source = 'pre_loan_deposit' and ep.status = 'pending' and ep.loan_id is null
      and ep.payment_date <= (now() at time zone 'Africa/Nairobi')::date
      and ep.excess_amount > coalesce(ep.released_amount, 0)
      and wamama_deposit_private.supervisor_can_transfer_for_member(
        actor.business_id::text, actor.id::text, actor.team_name::text, ep.member_id::text
      )
  );
end;
$$;

create or replace function public.pb_transfer_product_deposit_to_due_loan(
  p_deposit_id text,p_loan_id text,p_amount numeric,p_note text,p_request_id text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare actor public.pb_staff%rowtype;
begin
  select s.* into actor from public.pb_staff s
  where s.auth_user_id = auth.uid() and lower(coalesce(s.status::text, 'active')) = 'active'
  limit 1;
  if not found or lower(coalesce(actor.role::text,'')) not in ('admin','ceo','branch_manager','supervisor') then
    raise exception 'Only an active administrator, CEO, branch manager or supervisor can authorize this transfer.';
  end if;

  if lower(actor.role::text) = 'supervisor' and not exists (
    select 1 from public.pb_loans l
    where l.id::text = p_loan_id and l.business_id::text = actor.business_id::text
      and wamama_deposit_private.supervisor_can_transfer_for_member(
        actor.business_id::text, actor.id::text, actor.team_name::text, l.member_id::text
      )
  ) then
    raise exception 'Supervisors can authorize transfers only for clients in their assigned groups.';
  end if;

  return wamama_deposit_private.apply_product_deposit(
    actor.business_id::text,actor.id::text,p_deposit_id,p_loan_id,p_amount,p_note,p_request_id
  );
end;
$$;

revoke all on function public.pb_supervisor_product_deposits() from public,anon;
grant execute on function public.pb_supervisor_product_deposits() to authenticated;
revoke all on function public.pb_transfer_product_deposit_to_due_loan(text,text,numeric,text,text) from public,anon;
grant execute on function public.pb_transfer_product_deposit_to_due_loan(text,text,numeric,text,text) to authenticated;
commit;

select 'Scoped supervisor product deposit transfers enabled' as result;
