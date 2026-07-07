-- Wamama Pamoja: allow admins to give officers client-order creation rights.
-- Safe to run more than once.

alter table public.pb_permissions
add column if not exists can_submit_orders boolean not null default false;
