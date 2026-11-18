-- Wamama Pamoja Enterprise: READ-ONLY database timing check.
-- Requires the pg_stat_statements extension (enabled by default on Supabase).
-- Shows the most expensive API queries by total time. Query text is
-- truncated and parameters are anonymised by Postgres; no client data appears.
select
  calls,
  round(total_exec_time::numeric, 0)            as total_ms,
  round(mean_exec_time::numeric, 1)             as mean_ms,
  round(max_exec_time::numeric, 0)              as max_ms,
  rows                                          as rows_returned,
  round((shared_blks_read * 8 / 1024.0)::numeric, 1) as disk_read_mb,
  left(regexp_replace(query, '\s+', ' ', 'g'), 220) as query_start
from pg_stat_statements
where query ilike any (array['%pb\_%'])
order by total_exec_time desc
limit 25;
