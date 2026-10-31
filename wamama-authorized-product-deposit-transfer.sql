-- Authorized, partial transfer of a pre-loan product deposit to instalments due now.
-- Install once in Wamama Supabase. No existing balances change during setup.
begin;
create schema if not exists wamama_deposit_private;
revoke all on schema wamama_deposit_private from public,anon,authenticated;
create table if not exists wamama_deposit_private.product_deposit_transfers(
 request_id text primary key,business_id text not null,deposit_id text not null,loan_id text not null,
 amount numeric(14,2) not null,actor_id text not null,note text not null,repayment_id text not null,
 created_at timestamptz not null default now());
create unique index if not exists product_deposit_transfer_repayment_uidx on wamama_deposit_private.product_deposit_transfers(repayment_id);
alter table wamama_deposit_private.product_deposit_transfers enable row level security;
revoke all on wamama_deposit_private.product_deposit_transfers from public,anon,authenticated;
create or replace function wamama_deposit_private.apply_product_deposit(
 p_business_id text,p_actor_id text,p_deposit_id text,p_loan_id text,p_amount numeric,p_note text,p_request_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare dep public.pb_excess_payments%rowtype; target public.pb_loans%rowtype;
 prior wamama_deposit_private.product_deposit_transfers%rowtype;
 paid numeric; due_now numeric; principal_part numeric; repayment_id text; remaining numeric;
 today date:=(now() at time zone 'Africa/Nairobi')::date;
begin
 if p_request_id is null or length(p_request_id)<16 or nullif(trim(p_note),'') is null then raise exception 'A transfer reference and reason are required.'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Enter a positive transfer amount with at most two decimals.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('wamama-deposits:'||p_business_id,0));
 select * into prior from wamama_deposit_private.product_deposit_transfers where request_id=p_request_id;
 if found then
  if prior.business_id<>p_business_id or prior.deposit_id<>p_deposit_id or prior.loan_id<>p_loan_id or prior.amount<>p_amount then raise exception 'Transfer reference already used for different instructions.'; end if;
  return jsonb_build_object('amount',prior.amount,'repayment_id',prior.repayment_id,'already_applied',true);
 end if;
 select * into target from public.pb_loans where id::text=p_loan_id and business_id::text=p_business_id for update;
 if not found or lower(coalesce(target.status::text,''))<>'active' then raise exception 'Select an active loan in your business.'; end if;
 select * into dep from public.pb_excess_payments where id::text=p_deposit_id and business_id::text=p_business_id for update;
 if not found or dep.member_id::text<>target.member_id::text then raise exception 'Deposit and loan must belong to the same client and business.'; end if;
 if dep.source is distinct from 'pre_loan_deposit' or dep.status is distinct from 'pending' or dep.loan_id is not null or dep.payment_date is null or dep.payment_date>today then raise exception 'This is not an available pre-loan product deposit.'; end if;
 remaining:=round(dep.excess_amount-coalesce(dep.released_amount,0),2);
 if p_amount>remaining then raise exception 'Transfer exceeds the remaining product deposit (%).',remaining; end if;
 select coalesce(sum(r.amount),0) into paid from public.pb_repayments r where r.loan_id::text=p_loan_id and r.business_id::text=p_business_id
 and r.voided_at is null and lower(coalesce(r.status::text,'approved')) not in ('pending','rejected','cancelled','voided')
 and coalesce(r.meeting_date,(r.created_at at time zone 'Africa/Nairobi')::date)<=today;
 due_now:=round(greatest(0,least(target.total_payable,greatest(0,floor((today-target.start_date::date)/7.0)+1)*coalesce(target.weekly_installment,0))-paid),2);
 if target.start_date is null or target.start_date>today or p_amount>due_now then raise exception 'Only unpaid instalments already due can receive this transfer. Currently due: %.',due_now; end if;
 principal_part:=round(p_amount*coalesce(target.loan_value,0)/nullif(target.total_payable,0),2);
 insert into public.pb_repayments(business_id,loan_id,member_id,group_id,meeting_date,amount,principal,interest,recorded_by,status,notes)
 values(target.business_id,target.id,target.member_id,target.group_id,today,p_amount,principal_part,p_amount-principal_part,
 (select s.id from public.pb_staff s where s.id::text=p_actor_id and s.business_id::text=p_business_id limit 1),'approved',
 'Auto-deducted from pre-loan product deposit: '||dep.id::text||'; transfer '||p_request_id||'; '||p_note)
 returning id::text into repayment_id;
 update public.pb_excess_payments set released_amount=coalesce(released_amount,0)+p_amount,
 status=case when remaining-p_amount<=0.005 then 'applied_to_loan' else 'pending' end,
 last_released_at=now(),updated_at=now(),
 resolved_at=case when remaining-p_amount<=0.005 then now() else resolved_at end,
 resolution_reference=case when remaining-p_amount<=0.005 then 'Authorized product-deposit transfer: '||p_request_id else resolution_reference end
 where id=dep.id;
 insert into wamama_deposit_private.product_deposit_transfers(request_id,business_id,deposit_id,loan_id,amount,actor_id,note,repayment_id)
 values(p_request_id,p_business_id,p_deposit_id,p_loan_id,p_amount,p_actor_id,p_note,repayment_id);
 if paid+p_amount+0.005>=target.total_payable then update public.pb_loans set status='completed' where id=target.id; end if;
 return jsonb_build_object('amount',p_amount,'repayment_id',repayment_id,'deposit_remaining',remaining-p_amount,'due_remaining',due_now-p_amount,'already_applied',false);
end;$$;
revoke all on function wamama_deposit_private.apply_product_deposit(text,text,text,text,numeric,text,text) from public,anon,authenticated;
create or replace function public.pb_transfer_product_deposit_to_due_loan(p_deposit_id text,p_loan_id text,p_amount numeric,p_note text,p_request_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare actor public.pb_staff%rowtype;
begin
 select s.* into actor from public.pb_staff s where s.auth_user_id=auth.uid() and lower(coalesce(s.status,'active'))='active' limit 1;
 if not found or lower(coalesce(actor.role,'')) not in ('admin','ceo','branch_manager') then raise exception 'Only an active administrator, CEO or branch manager can authorize this transfer.'; end if;
 return wamama_deposit_private.apply_product_deposit(actor.business_id::text,actor.id::text,p_deposit_id,p_loan_id,p_amount,p_note,p_request_id);
end;$$;
revoke all on function public.pb_transfer_product_deposit_to_due_loan(text,text,numeric,text,text) from public,anon;
grant execute on function public.pb_transfer_product_deposit_to_due_loan(text,text,numeric,text,text) to authenticated;
create or replace function wamama_deposit_private.protect_transfer_repayment()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
 if exists(select 1 from wamama_deposit_private.product_deposit_transfers t where t.repayment_id=old.id::text) then
  if tg_op='DELETE' then raise exception 'An authorized deposit transfer cannot be deleted as a cash repayment. Review its deposit allocation.'; end if;
  if (to_jsonb(new)-'updated_at') is distinct from (to_jsonb(old)-'updated_at') then raise exception 'An authorized deposit transfer cannot be edited or voided as a cash repayment. Review its deposit allocation.'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;return new;
end;$$;
revoke all on function wamama_deposit_private.protect_transfer_repayment() from public,anon,authenticated;
drop trigger if exists pb_protect_product_deposit_transfer on public.pb_repayments;
create trigger pb_protect_product_deposit_transfer before update or delete on public.pb_repayments for each row execute function wamama_deposit_private.protect_transfer_repayment();
commit;
select 'Authorized partial product-deposit transfers installed; no financial records changed' result;
