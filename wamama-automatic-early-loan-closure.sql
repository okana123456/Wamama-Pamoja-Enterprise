-- Wamama Pamoja Enterprise
-- Permanent early-repayment closure rule.
-- Closes the specific loan when approved repayments reach total_payable,
-- regardless of its expected end date or the screen used to record payment.

create or replace function public.pb_reconcile_paid_loan(p_loan_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_payable numeric := 0;
  v_total_paid numeric := 0;
  v_status text;
  v_closed boolean := false;
begin
  if nullif(trim(p_loan_id), '') is null then
    return false;
  end if;

  select coalesce(l.total_payable, 0), lower(coalesce(l.status::text, ''))
    into v_total_payable, v_status
  from public.pb_loans l
  where l.id::text = p_loan_id
  for update;

  if not found or v_status <> 'active' or v_total_payable <= 0 then
    return false;
  end if;

  select coalesce(sum(coalesce(r.amount, 0)), 0)
    into v_total_paid
  from public.pb_repayments r
  where r.loan_id::text = p_loan_id
    and coalesce(lower(r.status::text), 'approved')
        not in ('pending', 'rejected', 'cancelled');

  if v_total_paid + 0.01 >= v_total_payable then
    update public.pb_loans l
       set status = 'completed'
     where l.id::text = p_loan_id
       and lower(coalesce(l.status::text, '')) = 'active';
    v_closed := found;
  end if;

  return v_closed;
end;
$$;

create or replace function public.pb_repayment_auto_close_loan_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.pb_reconcile_paid_loan(old.loan_id::text);
    return old;
  end if;

  perform public.pb_reconcile_paid_loan(new.loan_id::text);

  if tg_op = 'UPDATE' and old.loan_id::text is distinct from new.loan_id::text then
    perform public.pb_reconcile_paid_loan(old.loan_id::text);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_pb_repayment_auto_close_loan on public.pb_repayments;
create trigger trg_pb_repayment_auto_close_loan
after insert or update of amount, status, loan_id or delete
on public.pb_repayments
for each row
execute function public.pb_repayment_auto_close_loan_trigger();

-- Close any fully paid active loans that existed before this trigger.
with approved_totals as (
  select
    r.loan_id::text as loan_id_text,
    sum(coalesce(r.amount, 0)) as total_paid
  from public.pb_repayments r
  where coalesce(lower(r.status::text), 'approved')
        not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
)
update public.pb_loans l
set status = 'completed'
from approved_totals t
where l.id::text = t.loan_id_text
  and lower(coalesce(l.status::text, '')) = 'active'
  and coalesce(l.total_payable, 0) > 0
  and t.total_paid + 0.01 >= coalesce(l.total_payable, 0);

-- Prevent direct API users from calling the privileged helper functions.
revoke all on function public.pb_reconcile_paid_loan(text) from public, anon, authenticated;
revoke all on function public.pb_repayment_auto_close_loan_trigger() from public, anon, authenticated;

-- Verification: this must return zero.
select count(*) as active_fully_paid_loans_remaining
from public.pb_loans l
join (
  select
    r.loan_id::text as loan_id_text,
    sum(coalesce(r.amount, 0)) as total_paid
  from public.pb_repayments r
  where coalesce(lower(r.status::text), 'approved')
        not in ('pending', 'rejected', 'cancelled')
  group by r.loan_id::text
) t on t.loan_id_text = l.id::text
where lower(coalesce(l.status::text, '')) = 'active'
  and coalesce(l.total_payable, 0) > 0
  and t.total_paid + 0.01 >= coalesce(l.total_payable, 0);
