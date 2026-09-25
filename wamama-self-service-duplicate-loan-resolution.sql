-- Wamama Pamoja Enterprise
-- One-time setup for administrator self-service duplicate-loan resolution.
-- Existing records are not changed when this setup is installed.

begin;

create or replace function public.pb_resolve_duplicate_loan(
  p_duplicate_loan_id text,
  p_keep_loan_id text,
  p_payment_action text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_staff public.pb_staff%rowtype;
  v_duplicate public.pb_loans%rowtype;
  v_keep public.pb_loans%rowtype;
  v_deposit public.pb_excess_payments%rowtype;
  v_repayment public.pb_repayments%rowtype;
  v_gross numeric;
  v_voided integer:=0;
  v_moved integer:=0;
  v_releases integer:=0;
  v_deposits integer:=0;
begin
  if p_duplicate_loan_id is null or p_keep_loan_id is null
     or p_duplicate_loan_id=p_keep_loan_id then
    raise exception 'Choose two different loans: the duplicate and the loan to keep.';
  end if;
  if lower(coalesce(p_payment_action,'')) not in ('reverse','transfer') then
    raise exception 'Choose whether duplicate payments should be reversed or transferred.';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'Enter a short reason for resolving this duplicate.';
  end if;

  select s.* into v_staff
  from public.pb_staff s
  where s.auth_user_id=auth.uid()
    and lower(coalesce(s.status,'active'))='active'
  limit 1;
  if not found then raise exception 'Your active staff account was not found.'; end if;
  if lower(coalesce(v_staff.role,'')) not in ('admin','ceo','branch_manager','supervisor') then
    raise exception 'Only an administrator or manager can resolve duplicate loans.';
  end if;

  select * into v_duplicate from public.pb_loans
  where id::text=p_duplicate_loan_id and business_id::text=v_staff.business_id::text
  for update;
  if not found then raise exception 'The duplicate loan was not found.'; end if;

  select * into v_keep from public.pb_loans
  where id::text=p_keep_loan_id and business_id::text=v_staff.business_id::text
  for update;
  if not found then raise exception 'The loan to keep was not found.'; end if;

  if v_duplicate.member_id::text is distinct from v_keep.member_id::text then
    raise exception 'Both loans must belong to the same client.';
  end if;
  if lower(coalesce(v_duplicate.status::text,''))<>'active'
     or lower(coalesce(v_keep.status::text,''))<>'active' then
    raise exception 'Both selected loans must still be active.';
  end if;

  -- Reverse every generated repayment release connected to a deposit sourced
  -- from the duplicate loan. The repayment row remains as a voided audit row.
  update public.pb_repayments r
  set voided_at=coalesce(r.voided_at,now()),
      voided_by=coalesce(r.voided_by,v_staff.id::text),
      void_reason=coalesce(r.void_reason,'Duplicate-loan resolution'),
      edit_notes=case when r.voided_at is null then concat_ws(' | ',nullif(r.edit_notes,''),
        'VOID: duplicate-loan deposit release reversal') else r.edit_notes end,
      updated_at=now()
  where r.id::text in (
    select pr.repayment_id
    from public.pb_prepayment_releases pr
    join public.pb_excess_payments ep on ep.id::text=pr.prepayment_id
    where ep.business_id=v_staff.business_id::text
      and (ep.loan_id=p_duplicate_loan_id or ep.original_repayment_id in (
        select id::text from public.pb_repayments where loan_id::text=p_duplicate_loan_id
      ))
  );
  get diagnostics v_releases=row_count;

  delete from public.pb_prepayment_releases pr
  using public.pb_excess_payments ep
  where ep.id::text=pr.prepayment_id
    and ep.business_id=v_staff.business_id::text
    and (ep.loan_id=p_duplicate_loan_id or ep.original_repayment_id in (
      select id::text from public.pb_repayments where loan_id::text=p_duplicate_loan_id
    ));

  if lower(p_payment_action)='reverse' then
    update public.pb_excess_payments ep
    set status='refunded',released_amount=0,last_released_at=null,
        resolved_at=now(),resolved_by=v_staff.id::text,
        resolution_reference='Duplicate-loan accounting reversal',
        notes=concat_ws(' | ',nullif(ep.notes,''),trim(p_reason)),updated_at=now()
    where ep.business_id=v_staff.business_id::text
      and (ep.loan_id=p_duplicate_loan_id or ep.original_repayment_id in (
        select id::text from public.pb_repayments where loan_id::text=p_duplicate_loan_id
      ));
    get diagnostics v_deposits=row_count;

    update public.pb_repayments
    set status='cancelled',edit_notes=concat_ws(' | ',nullif(edit_notes,''),
      'CANCELLED: duplicate loan resolved — '||trim(p_reason)),updated_at=now()
    where business_id::text=v_staff.business_id::text
      and loan_id::text=p_duplicate_loan_id
      and lower(coalesce(status,''))='pending';

    update public.pb_repayments r
    set voided_at=coalesce(r.voided_at,now()),
        voided_by=coalesce(r.voided_by,v_staff.id::text),
        void_reason=coalesce(r.void_reason,trim(p_reason)),
        edit_notes=case when r.voided_at is null then concat_ws(' | ',nullif(r.edit_notes,''),
          'VOID: duplicate loan resolved — '||trim(p_reason)) else r.edit_notes end,
        updated_at=now()
    where r.business_id::text=v_staff.business_id::text
      and r.loan_id::text=p_duplicate_loan_id
      and r.voided_at is null;
    get diagnostics v_voided=row_count;
  else
    -- Restore resolved deposits to an editable state before moving their source
    -- payments. The repayment allocation trigger then recalculates each payment
    -- against the kept loan on its original cash date.
    update public.pb_excess_payments ep
    set status='refunded',released_amount=0,last_released_at=null,
        resolved_at=now(),resolved_by=v_staff.id::text,
        resolution_reference='Voided payment on cancelled duplicate loan',
        notes=concat_ws(' | ',nullif(ep.notes,''),trim(p_reason)),updated_at=now()
    where ep.business_id=v_staff.business_id::text
      and (ep.loan_id=p_duplicate_loan_id or ep.original_repayment_id in (
        select id::text from public.pb_repayments where loan_id::text=p_duplicate_loan_id
      ))
      and exists (select 1 from public.pb_repayments r
        where r.id::text=ep.original_repayment_id and r.voided_at is not null);

    update public.pb_excess_payments ep
    set loan_id=p_keep_loan_id,group_id=v_keep.group_id::text,
        status='pending',released_amount=0,last_released_at=null,
        resolution_reference=null,resolved_at=null,resolved_by=null,
        notes=concat_ws(' | ',nullif(ep.notes,''),
          'Transferred from duplicate loan '||p_duplicate_loan_id||': '||trim(p_reason)),
        updated_at=now()
    where ep.business_id=v_staff.business_id::text
      and ep.original_repayment_id in (
        select id::text from public.pb_repayments
        where loan_id::text=p_duplicate_loan_id and voided_at is null
          and coalesce(notes,'') not like 'Scheduled prepayment release:%'
      );
    get diagnostics v_deposits=row_count;

    for v_repayment in
      select r.* from public.pb_repayments r
      where r.business_id::text=v_staff.business_id::text
        and r.loan_id::text=p_duplicate_loan_id
        and r.voided_at is null
        and (
          lower(coalesce(r.status,'approved')) not in ('pending','rejected','cancelled')
          or exists (select 1 from public.pb_excess_payments ep
            where ep.original_repayment_id=r.id::text)
        )
        and coalesce(r.notes,'') not like 'Scheduled prepayment release:%'
      order by coalesce(r.meeting_date,r.created_at::date),r.created_at,r.id
      for update
    loop
      select ep.* into v_deposit from public.pb_excess_payments ep
      where ep.original_repayment_id=v_repayment.id::text limit 1;
      v_gross:=coalesce(v_deposit.original_payment_amount,v_repayment.amount);

      update public.pb_repayments
      set loan_id=v_keep.id,group_id=v_keep.group_id,
          amount=v_gross,status='approved',
          edit_notes=concat_ws(' | ',nullif(edit_notes,''),
            'Transferred from duplicate loan '||p_duplicate_loan_id||': '||trim(p_reason)),
          updated_at=now()
      where id=v_repayment.id;
      v_moved:=v_moved+1;
    end loop;

    update public.pb_repayments
    set status='cancelled',edit_notes=concat_ws(' | ',nullif(edit_notes,''),
      'CANCELLED: duplicate loan resolved — '||trim(p_reason)),updated_at=now()
    where business_id::text=v_staff.business_id::text
      and loan_id::text=p_duplicate_loan_id
      and lower(coalesce(status,''))='pending';

    -- Rows already voided or rejected remain attached to the cancelled loan as
    -- history. They never contribute to balances.
  end if;

  update public.pb_loans
  set status='cancelled',updated_at=now()
  where id=v_duplicate.id;

  insert into public.pb_audit_log(
    business_id,staff_id,staff_name,action,entity,entity_id,old_value,new_value
  ) values (
    v_staff.business_id,v_staff.id,coalesce(v_staff.full_name,'System'),
    'resolve_duplicate_loan','pb_loans',v_duplicate.id::text,
    jsonb_build_object('duplicate_loan_id',v_duplicate.id,'status','active',
      'member_id',v_duplicate.member_id,'asset_name',v_duplicate.asset_name),
    jsonb_build_object('status','cancelled','kept_loan_id',v_keep.id,
      'payment_action',lower(p_payment_action),'reason',trim(p_reason),
      'repayments_voided',v_voided,'repayments_moved',v_moved,
      'deposits_resolved',v_deposits,'release_repayments_voided',v_releases)
  );

  return jsonb_build_object('success',true,'duplicate_loan_id',v_duplicate.id,
    'kept_loan_id',v_keep.id,'payment_action',lower(p_payment_action),
    'repayments_voided',v_voided,'repayments_moved',v_moved,
    'deposits_resolved',v_deposits,'release_repayments_voided',v_releases);
end;
$$;

revoke all on function public.pb_resolve_duplicate_loan(text,text,text,text) from public;
grant execute on function public.pb_resolve_duplicate_loan(text,text,text,text) to authenticated;

commit;

select 'Self-service duplicate-loan resolution is ready' as result;
