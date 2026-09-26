-- Wamama: cancel an incorrectly created loan without erasing reversed history.
-- Run this complete setup in the Wamama Supabase SQL Editor.
-- Installing it does not cancel or change any existing loan.
begin;

create or replace function public.pb_cancel_unused_loan(p_loan_id text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_loan public.pb_loans%rowtype;
  v_old jsonb;
  v_table text;
  v_linked boolean;
  v_history integer;
begin
  select s.* into v_staff from public.pb_staff s
  where s.auth_user_id=auth.uid() and lower(coalesce(s.status,'active'))='active'
  limit 1;
  if not found then raise exception 'Please sign in again.'; end if;
  if lower(coalesce(v_staff.role,'')) not in ('admin','ceo','branch_manager') then
    raise exception 'Only an administrator or branch manager can cancel an incorrect loan.';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'Enter a short reason for cancelling this loan.';
  end if;

  -- Serialize the checks with accounting writes, including text loan links
  -- without foreign keys. These brief locks prevent a payment arriving between
  -- the eligibility check and cancellation. No accounting rows are changed.
  lock table public.pb_repayments in share row exclusive mode;
  foreach v_table in array array['pb_excess_payments','pb_prepayment_releases','pb_preloan_deposit_applications'] loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  select l.* into v_loan from public.pb_loans l
  where l.id::text=p_loan_id and l.business_id::text=v_staff.business_id::text
  for update;
  if not found then raise exception 'This loan was not found in your business.'; end if;
  if lower(coalesce(v_loan.status::text,''))='cancelled' then
    return jsonb_build_object('success',true,'loan_id',v_loan.id,'status','cancelled','already_cancelled',true);
  end if;
  if lower(coalesce(v_loan.status::text,'')) not in ('active','pending') then
    raise exception 'Only an active or pending incorrect loan can be cancelled here.';
  end if;

  -- Voided/rejected/cancelled repayments stay attached as audit history.
  -- Check all dates, including future-dated payments and pending receipts.
  if exists(select 1 from public.pb_repayments r
    where r.loan_id::text=p_loan_id
      and r.voided_at is null
      and lower(coalesce(r.status,'approved')) not in ('rejected','cancelled','voided')
      and (coalesce(r.amount,0)<>0 or coalesce(r.principal,0)<>0 or coalesce(r.interest,0)<>0)) then
    raise exception 'This loan has an active or pending payment. Resolve that payment before cancelling the loan.';
  end if;
  if coalesce((to_jsonb(v_loan)->>'deposit_applied')::numeric,0)<>0 then
    raise exception 'A deposit was used to fund this loan. Resolve the deposit before cancelling the loan.';
  end if;
  foreach v_table in array array['pb_excess_payments','pb_prepayment_releases','pb_preloan_deposit_applications'] loop
    if to_regclass('public.'||v_table) is not null then
      execute format('select exists(select 1 from public.%I where loan_id::text=$1)',v_table)
        into v_linked using p_loan_id;
      if v_linked then
        raise exception 'This loan has linked deposit records. Resolve the deposits before cancelling the loan.';
      end if;
    end if;
  end loop;
  -- Some legacy deposit links point at the source repayment instead of the loan.
  if to_regclass('public.pb_excess_payments') is not null then
    execute 'select exists(select 1 from public.pb_excess_payments ep
      join public.pb_repayments r on r.id::text=ep.original_repayment_id::text
      where r.loan_id::text=$1)' into v_linked using p_loan_id;
    if v_linked then
      raise exception 'This loan has linked deposit records. Resolve the deposits before cancelling the loan.';
    end if;
  end if;

  v_old:=to_jsonb(v_loan);
  select count(*) into v_history from public.pb_repayments where loan_id::text=p_loan_id;
  update public.pb_loans set status='cancelled',updated_at=now() where id=v_loan.id;
  insert into public.pb_audit_log(business_id,staff_id,staff_name,action,entity,entity_id,old_value,new_value)
  values(v_staff.business_id,v_staff.id,v_staff.full_name,'cancel_unused_loan','pb_loans',v_loan.id::text,
    v_old,jsonb_build_object('status','cancelled','reason',trim(p_reason),'retained_repayment_rows',v_history));
  return jsonb_build_object('success',true,'loan_id',v_loan.id,'status','cancelled','retained_repayment_rows',v_history);
end;
$$;

revoke all on function public.pb_cancel_unused_loan(text,text) from public,anon;
grant execute on function public.pb_cancel_unused_loan(text,text) to authenticated;
commit;

select to_regprocedure('public.pb_cancel_unused_loan(text,text)') is not null as cancel_unused_loan_ready;
