-- Wamama function security hardening. No business rows are rewritten.
-- SQL Editor: run the entire file. Keeps necessary authenticated RPC access.
-- Definitions/privileges are backed up in a private, API-inaccessible schema.
DO $harden_functions$
declare
 f record; proc_oid oid; current_definition text; current_hash text;
 saved record; new_definition text; permission_guard text;
begin
 if not exists(select 1 from public.pb_staff where business_id::text='b3462eea-1c92-4411-9507-fb6c0b31ba28') then
   raise exception 'Wamama business not found. No changes made.';
 end if;
 create schema if not exists wamama_security_private;
 revoke all on schema wamama_security_private from public,anon,authenticated;
 create table if not exists wamama_security_private.functions_20261021(
 signature text primary key,original_definition text not null,original_acl aclitem[],
 original_owner text not null,applied_hash text,secured_at timestamptz not null default now());
 alter table wamama_security_private.functions_20261021 enable row level security;
 revoke all on wamama_security_private.functions_20261021 from public,anon,authenticated;
 -- Validate every definition before making changes. Repeat runs verify the secured version.
 for f in select * from (values
('public.get_my_business_id()','e051aac25ad894cbd0d8c5e0a0e18e00',true,false),
('public.pb_admin_billing_open_for_current_user()','c54a3ba1476b2cc494a928c799ce7fb5',true,false),
('public.pb_apply_preloan_deposit_to_loan(text,text,numeric)','ada7539571d9a98ec449778517435b60',true,false),
('public.pb_approve_savings(text[])','e5978f62853b787331b90b5a03533fbc',true,false),
('public.pb_approve_sold_items_loan(text)','26efbec4d25406de81b9c9d3f93459d2',true,false),
('public.pb_approve_sold_items_loan_group(text,text)','b92319f640d3623d2fcc1ebe3faadfd9',true,false),
('public.pb_attach_preloan_deposits()','f0133eabd5ba1e703240bacd7f30e4d6',true,true),
('public.pb_block_rapid_duplicate_pending_repayment()','39700884872b38e95a156f2e956f0859',true,true),
('public.pb_can_manage_excess_payments()','9265168e831ec58126fe3b5ab7a2698e',true,false),
('public.pb_cancel_unused_loan(text,text)','3a803e932ef0114fdaecec532601adae',true,false),
('public.pb_capture_repayment_excess()','d87683be0fc38d13fa03b76d4fac56cd',true,true),
('public.pb_cash_collection_totals(date,date)','67be753403005764f2db7fb222e214ad',true,false),
('public.pb_close_paid_loan_early(text)','dde90e06c4fa153b29c4d8b4e0a1dbb2',true,false),
('public.pb_current_business_id_text()','539f944d7ebe23f022ef5a84b9dea7b3',true,false),
('public.pb_current_staff_id_text()','eafaff0e7c23aa5348f2b96677d3e251',true,false),
('public.pb_guard_inventory_reference_prices()','78fd61e05d20ef5387b54b24fca819a5',false,true),
('public.pb_inventory_reference_prices()','422aa5caa83c5ffa5e35dafc102196d3',true,false),
('public.pb_officer_book_activity(date,date)','ecbff0a61f24e4ac522139fb82e52253',true,false),
('public.pb_protect_excess_source_repayment()','2d1fd80dcd9be26fea684b72112e070a',true,true),
('public.pb_reconcile_paid_loan(text)','2089012c4b662c9365643af15f04a5d7',false,false),
('public.pb_record_preloan_deposit(text,numeric,date,text)','c769e6bcd95bfc99d2e30442375a210f',true,false),
('public.pb_record_repayments_batch(jsonb)','6f736d61936152f6d95d588faf11edb4',true,false),
('public.pb_register_business_admin(uuid,text,text,text,text)','c22a7176d791f7483c6f1104dbfe1f1f',true,false),
('public.pb_release_due_prepayments(text[],integer)','a59b4908d9f5aef490da692155e7460b',true,false),
('public.pb_repayment_auto_close_loan_trigger()','96ae8b2cbb11be3620d65710fb42d4a2',false,true),
('public.pb_resolve_duplicate_loan(text,text,text,text)','03a769f78fccddafa9b5fd3042eb5d49',true,false),
('public.pb_resolve_excess_as_refund(uuid,text,text)','06ca5252a282dc2fafb39776affc0159',true,false),
('public.pb_resolve_excess_to_loan(uuid,text,text)','e8bf5d919280509f4dac376c5aa5ec33',true,false),
('public.pb_resolve_excess_to_savings(uuid,text)','93bf8dd28afd3f53ddddcdf98a7ebb1f',true,false),
('public.pb_set_inventory_reference_prices(uuid,numeric,numeric)','f00720a682940ab80e14cbef0e25b688',true,false),
('public.pb_transfer_officer_book(uuid,uuid,text)','7145f508686b88da5693cd405e2f9b1d',true,false),
('public.pb_transfer_officer_book(text,text,text[],text)','b91a8d83c08e54bbebdea2b4dbf48aa8',true,false),
('public.pb_visible_loan_deposit_balances()','2ac695c3663ec9376ad895d7471415e6',true,false),
('public.pb_void_repayment(text,text)','a851280adf52abae8116f5f593635193',true,false),
('public.pb_keep_loan_price_on_legacy_receipt()','c0f28fcb9fdb6900e0f06e9ad1698514',true,true)
 ) m(signature,expected_hash,allow_authenticated,is_trigger)
 loop
   proc_oid:=to_regprocedure(f.signature);
   if proc_oid is null then raise exception 'Reviewed function missing: %',f.signature; end if;
   current_definition:=pg_get_functiondef(proc_oid);
   current_hash:=md5(regexp_replace(replace(current_definition,chr(13),''),'[[:space:]]+$','','g'));
   select * into saved from wamama_security_private.functions_20261021 where signature=f.signature;
   if found then
     if saved.applied_hash is distinct from current_hash then
       raise exception 'Function changed since hardening: %. Run a fresh security review.',f.signature;
     end if;
   elsif current_hash<>f.expected_hash then
     raise exception 'Function changed since review: %. Run a fresh security review.',f.signature;
   else
     insert into wamama_security_private.functions_20261021(signature,original_definition,original_acl,original_owner)
       select f.signature,current_definition,p.proacl,pg_get_userbyid(p.proowner) from pg_proc p where p.oid=proc_oid;
   end if;
 end loop;
 -- Restrict privileged operations to a verified signed-in business manager.
 for f in select signature from wamama_security_private.functions_20261021
   where signature in ('public.pb_transfer_officer_book(uuid,uuid,text)',
     'public.pb_transfer_officer_book(text,text,text[],text)')
 loop
   new_definition:=pg_get_functiondef(to_regprocedure(f.signature));
   if f.signature='public.pb_transfer_officer_book(uuid,uuid,text)' then
     execute $legacy$
       create or replace function public.pb_transfer_officer_book(from_officer_id uuid,to_officer_id uuid,transfer_note text default null)
       returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp
       as $legacy_body$
       begin
         -- WAMAMA_SECURITY_20261021: delegate to the checked, mixed-ID-safe operation.
         return public.pb_transfer_officer_book(from_officer_id::text,to_officer_id::text,array[]::text[],transfer_note);
       end;
       $legacy_body$;
     $legacy$;
   elsif position('-- WAMAMA_SECURITY_20261021' in new_definition)=0 then
     permission_guard:=$guard$
  -- WAMAMA_SECURITY_20261021
  if auth.uid() is null or not exists(
    select 1 from public.pb_staff actor
    join public.pb_staff source_staff on source_staff.id::text=from_officer_id::text
    where actor.auth_user_id=auth.uid()
      and lower(coalesce(actor.status,'active'))='active'
      and actor.business_id::text=source_staff.business_id::text
      and lower(coalesce(actor.role,'')) in ('admin','ceo','branch_manager')
  ) then raise exception 'Only an active manager of this business may transfer an officer book.'; end if;
$guard$;
     new_definition:=regexp_replace(new_definition,'(?i)\mbegin\M','BEGIN'||permission_guard);
     execute new_definition;
   end if;
 end loop;
 -- Registration must create only the authenticated caller's own first staff account.
 new_definition:=pg_get_functiondef('public.pb_register_business_admin(uuid,text,text,text,text)'::regprocedure);
 if position('-- WAMAMA_SECURITY_20261021' in new_definition)=0 then
   permission_guard:=$guard$
  -- WAMAMA_SECURITY_20261021
  if auth.uid() is null or auth.uid() is distinct from p_auth_user_id then
    raise exception 'Confirm your email and sign in before registering your own business.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_auth_user_id::text,0));
  if exists(select 1 from public.pb_staff where auth_user_id=p_auth_user_id) then
    raise exception 'This account already has a staff profile. Sign in to the existing business.';
  end if;
$guard$;
   new_definition:=regexp_replace(new_definition,'(?i)\mbegin\M','BEGIN'||permission_guard);
   new_definition:=replace(new_definition,'IF p_registration_key !=','IF p_registration_key IS DISTINCT FROM');
   new_definition:=replace(new_definition,'INSERT INTO pb_settings','INSERT INTO public.pb_settings');
   new_definition:=replace(new_definition,'INSERT INTO pb_staff','INSERT INTO public.pb_staff');
   new_definition:=replace(new_definition,'INSERT INTO pb_permissions','INSERT INTO public.pb_permissions');
   execute new_definition;
 end if;
 for f in select * from (values
('public.get_my_business_id()','e051aac25ad894cbd0d8c5e0a0e18e00',true,false),
('public.pb_admin_billing_open_for_current_user()','c54a3ba1476b2cc494a928c799ce7fb5',true,false),
('public.pb_apply_preloan_deposit_to_loan(text,text,numeric)','ada7539571d9a98ec449778517435b60',true,false),
('public.pb_approve_savings(text[])','e5978f62853b787331b90b5a03533fbc',true,false),
('public.pb_approve_sold_items_loan(text)','26efbec4d25406de81b9c9d3f93459d2',true,false),
('public.pb_approve_sold_items_loan_group(text,text)','b92319f640d3623d2fcc1ebe3faadfd9',true,false),
('public.pb_attach_preloan_deposits()','f0133eabd5ba1e703240bacd7f30e4d6',true,true),
('public.pb_block_rapid_duplicate_pending_repayment()','39700884872b38e95a156f2e956f0859',true,true),
('public.pb_can_manage_excess_payments()','9265168e831ec58126fe3b5ab7a2698e',true,false),
('public.pb_cancel_unused_loan(text,text)','3a803e932ef0114fdaecec532601adae',true,false),
('public.pb_capture_repayment_excess()','d87683be0fc38d13fa03b76d4fac56cd',true,true),
('public.pb_cash_collection_totals(date,date)','67be753403005764f2db7fb222e214ad',true,false),
('public.pb_close_paid_loan_early(text)','dde90e06c4fa153b29c4d8b4e0a1dbb2',true,false),
('public.pb_current_business_id_text()','539f944d7ebe23f022ef5a84b9dea7b3',true,false),
('public.pb_current_staff_id_text()','eafaff0e7c23aa5348f2b96677d3e251',true,false),
('public.pb_guard_inventory_reference_prices()','78fd61e05d20ef5387b54b24fca819a5',false,true),
('public.pb_inventory_reference_prices()','422aa5caa83c5ffa5e35dafc102196d3',true,false),
('public.pb_officer_book_activity(date,date)','ecbff0a61f24e4ac522139fb82e52253',true,false),
('public.pb_protect_excess_source_repayment()','2d1fd80dcd9be26fea684b72112e070a',true,true),
('public.pb_reconcile_paid_loan(text)','2089012c4b662c9365643af15f04a5d7',false,false),
('public.pb_record_preloan_deposit(text,numeric,date,text)','c769e6bcd95bfc99d2e30442375a210f',true,false),
('public.pb_record_repayments_batch(jsonb)','6f736d61936152f6d95d588faf11edb4',true,false),
('public.pb_register_business_admin(uuid,text,text,text,text)','c22a7176d791f7483c6f1104dbfe1f1f',true,false),
('public.pb_release_due_prepayments(text[],integer)','a59b4908d9f5aef490da692155e7460b',true,false),
('public.pb_repayment_auto_close_loan_trigger()','96ae8b2cbb11be3620d65710fb42d4a2',false,true),
('public.pb_resolve_duplicate_loan(text,text,text,text)','03a769f78fccddafa9b5fd3042eb5d49',true,false),
('public.pb_resolve_excess_as_refund(uuid,text,text)','06ca5252a282dc2fafb39776affc0159',true,false),
('public.pb_resolve_excess_to_loan(uuid,text,text)','e8bf5d919280509f4dac376c5aa5ec33',true,false),
('public.pb_resolve_excess_to_savings(uuid,text)','93bf8dd28afd3f53ddddcdf98a7ebb1f',true,false),
('public.pb_set_inventory_reference_prices(uuid,numeric,numeric)','f00720a682940ab80e14cbef0e25b688',true,false),
('public.pb_transfer_officer_book(uuid,uuid,text)','7145f508686b88da5693cd405e2f9b1d',true,false),
('public.pb_transfer_officer_book(text,text,text[],text)','b91a8d83c08e54bbebdea2b4dbf48aa8',true,false),
('public.pb_visible_loan_deposit_balances()','2ac695c3663ec9376ad895d7471415e6',true,false),
('public.pb_void_repayment(text,text)','a851280adf52abae8116f5f593635193',true,false),
('public.pb_keep_loan_price_on_legacy_receipt()','c0f28fcb9fdb6900e0f06e9ad1698514',true,true)
 ) m(signature,expected_hash,allow_authenticated,is_trigger)
 loop
   execute format('alter function %s set search_path = pg_catalog, public, pg_temp',f.signature);
   execute format('revoke all on function %s from public, anon',f.signature);
   if f.is_trigger or not f.allow_authenticated then
     execute format('revoke all on function %s from authenticated',f.signature);
   else
     execute format('grant execute on function %s to authenticated',f.signature);
   end if;
   if has_function_privilege('anon',to_regprocedure(f.signature),'EXECUTE') then
     raise exception 'Signed-out execution is still enabled for %. Changes rolled back.',f.signature;
   end if;
   update wamama_security_private.functions_20261021 set
     applied_hash=md5(regexp_replace(replace(pg_get_functiondef(to_regprocedure(f.signature)),chr(13),''),'[[:space:]]+$','','g'))
   where signature=f.signature;
 end loop;
end;
$harden_functions$;

select count(*) reviewed_functions,
 count(*) filter(where has_function_privilege('anon',to_regprocedure(b.signature),'EXECUTE')) signed_out_executable_remaining,
 count(*) filter(where not exists(select 1 from unnest(p.proconfig) setting where setting like 'search_path=%')) missing_search_paths,
 'Function security hardened; business records preserved' result
from wamama_security_private.functions_20261021 b join pg_proc p on p.oid=to_regprocedure(b.signature);
