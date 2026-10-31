-- Install only: management-authorized returns, stock recovery and payment settlement.
begin;
alter table public.pb_loans add column if not exists return_settlement jsonb;
create schema if not exists wamama_returns_private;
revoke all on schema wamama_returns_private from public,anon,authenticated;
create table if not exists wamama_returns_private.settlements(
 loan_id text primary key,business_id text not null,request_id text unique not null,actor_id text not null,
 result jsonb not null,created_at timestamptz not null default now());
alter table wamama_returns_private.settlements enable row level security;
revoke all on wamama_returns_private.settlements from public,anon,authenticated;
create or replace function public.pb_return_loan(p_loan_id text,p_reason text,p_refund numeric default null,p_retained numeric default null,p_credit numeric default null,p_refund_reference text default null,p_stock jsonb default '[]',p_request_id text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare actor public.pb_staff%rowtype; target public.pb_loans%rowtype; dep record; line jsonb; inv public.pb_inventory%rowtype;
 paid numeric; held numeric:=0; funding numeric; total numeric; result jsonb; prior record; credit_id text; expense_id text; seen text[]:='{}';
begin
 select s.* into actor from public.pb_staff s where s.auth_user_id=auth.uid() and lower(coalesce(s.status,'active'))='active' limit 1;
 if not found or lower(coalesce(actor.role,'')) not in ('admin','ceo','branch_manager') then raise exception 'Only active management can return and cancel a loan.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('wamama-deposits:'||actor.business_id::text,0));
 -- Serialize cash/deposit writes before determining the final settlement.
 lock table public.pb_repayments in share row exclusive mode;
 lock table public.pb_excess_payments in share row exclusive mode;
 select * into target from public.pb_loans where id::text=p_loan_id and business_id::text=actor.business_id::text for update;
 if not found then raise exception 'Loan not found in your business.'; end if;
 select * into prior from wamama_returns_private.settlements where loan_id=p_loan_id;
 if found then return prior.result||jsonb_build_object('already_settled',true); end if;
 if target.status not in ('active','defaulted','pending') then raise exception 'Only a running or pending loan can be returned here.'; end if;
 if exists(select 1 from public.pb_repayments r where r.loan_id::text=p_loan_id and r.business_id::text=actor.business_id::text and r.voided_at is null and lower(coalesce(r.status,'approved'))='pending' and r.amount<>0) then raise exception 'Approve or reject the pending payment first so the return uses a confirmed cash balance.'; end if;
 select coalesce(sum(r.amount),0) into paid from public.pb_repayments r where r.loan_id::text=p_loan_id and r.business_id::text=actor.business_id::text and r.voided_at is null and lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled','voided');
 for dep in select ep.* from public.pb_excess_payments ep where ep.business_id::text=actor.business_id::text and ep.member_id::text=target.member_id::text and ep.status='pending'
 and (ep.loan_id::text=p_loan_id or ep.original_repayment_id::text in(select r.id::text from public.pb_repayments r where r.loan_id::text=p_loan_id and r.business_id::text=actor.business_id::text)) for update loop
 held:=held+greatest(0,dep.excess_amount-coalesce(dep.released_amount,0));
 end loop;
 funding:=coalesce((to_jsonb(target)->>'deposit_applied')::numeric,0);
 total:=round(paid+held+funding,2);
 if p_refund is null and p_retained is null and p_credit is null then return jsonb_build_object('loan_id',target.id,'confirmed_payments',paid,'held_deposits',held,'funding_deposit',funding,'settlement_total',total); end if;
 if p_request_id is null or length(p_request_id)<16 or length(trim(coalesce(p_reason,'')))<5 then raise exception 'A reason and unique return reference are required.'; end if;
 if p_refund is null or p_retained is null or p_credit is null or least(p_refund,p_retained,p_credit)<0 or round(p_refund+p_retained+p_credit,2)<>total then raise exception 'Refund, retained charge and client deposit must add up to the confirmed total (%).',total; end if;
 if p_refund<>round(p_refund,2) or p_retained<>round(p_retained,2) or p_credit<>round(p_credit,2) then raise exception 'Use amounts with at most two decimal places.'; end if;
 if p_refund>0 and nullif(trim(p_refund_reference),'') is null then raise exception 'Enter the reference for the refund actually paid to the client.'; end if;
 if jsonb_typeof(p_stock)<>'array' then raise exception 'Returned stock must be a list.'; end if;
 if target.status='pending' and jsonb_array_length(p_stock)>0 then raise exception 'A pending loan has not issued stock. Do not add it back again.'; end if;
 for line in select value from jsonb_array_elements(p_stock) order by value->>'asset_id' loop
 if nullif(line->>'asset_id','') is null or line->>'quantity' is null or (line->>'quantity')::numeric<=0 or (line->>'quantity')::numeric<>trunc((line->>'quantity')::numeric) then raise exception 'Choose an inventory item and a whole positive return quantity.'; end if;
 if line->>'asset_id'=any(seen) then raise exception 'Use each returned inventory item once.'; end if;seen:=array_append(seen,line->>'asset_id');
 select * into inv from public.pb_inventory where id::text=line->>'asset_id' and business_id::text=actor.business_id::text for update;
 if not found then raise exception 'Returned item is not in your business inventory.'; end if;
 -- Management may map legacy product names manually; the selected items/quantities are audited.
 update public.pb_inventory set stock=coalesce(stock,0)+(line->>'quantity')::numeric where id=inv.id;
 end loop;
 if p_refund>0 then
 insert into public.pb_expenses(business_id,date,category,amount,description,recorded_by)
 values(actor.business_id,(now() at time zone 'Africa/Nairobi')::date,'Other',p_refund,
 'Client goods-return refund; loan '||p_loan_id||'; reference '||p_refund_reference||'; '||p_reason,actor.id) returning id::text into expense_id;
 end if;
 if p_credit>0 then
 insert into public.pb_excess_payments(business_id,member_id,group_id,loan_id,payment_date,excess_amount,released_amount,source,status,original_payment_amount,amount_applied_to_loan,notes)
 values(actor.business_id::text,target.member_id::text,target.group_id::text,null,(now() at time zone 'Africa/Nairobi')::date,p_credit,0,'pre_loan_deposit','pending',0,0,'Client credit from returned loan '||p_loan_id||'; '||p_reason)
 returning id::text into credit_id;
 end if;
 update public.pb_excess_payments ep set released_amount=ep.excess_amount,status='applied_to_loan',updated_at=now(),resolved_at=now(),resolution_reference='Settled on goods return: '||p_request_id
 where ep.business_id::text=actor.business_id::text and ep.member_id::text=target.member_id::text and ep.status='pending'
 and (ep.loan_id::text=p_loan_id or ep.original_repayment_id::text in(select r.id::text from public.pb_repayments r where r.loan_id::text=p_loan_id and r.business_id::text=actor.business_id::text));
 result:=jsonb_build_object('success',true,'loan_id',target.id,'status','cancelled','reason',trim(p_reason),'confirmed_payments',paid,'held_deposits',held,'funding_deposit',funding,'settlement_total',total,'refund',p_refund,'refund_reference',p_refund_reference,'refund_expense_id',expense_id,'retained',p_retained,'client_credit',p_credit,'credit_deposit_id',credit_id,'returned_stock',p_stock,'actor_id',actor.id,'settled_at',now(),'request_id',p_request_id);
 update public.pb_loans set status='cancelled',return_settlement=result,updated_at=now() where id=target.id;
 insert into wamama_returns_private.settlements(loan_id,business_id,request_id,actor_id,result) values(p_loan_id,actor.business_id::text,p_request_id,actor.id::text,result);
 insert into public.pb_audit_log(business_id,staff_id,staff_name,action,entity,entity_id,old_value,new_value)
 values(actor.business_id,actor.id,actor.full_name,'goods_return_loan_cancellation','pb_loans',p_loan_id,to_jsonb(target),result);
 return result;
end;$$;
revoke all on function public.pb_return_loan(text,text,numeric,numeric,numeric,text,jsonb,text) from public,anon;
grant execute on function public.pb_return_loan(text,text,numeric,numeric,numeric,text,jsonb,text) to authenticated;
commit;
select 'Management goods-return and payment-settlement controls installed; existing loans unchanged' result;
