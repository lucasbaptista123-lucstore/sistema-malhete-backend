-- asaas_credenciais: proteção só pelo GRANT (execute apenas para service_role).
-- A checagem extra do claim 'role' não é garantida com as chaves secretas novas (sb_secret_…).
create or replace function public.asaas_credenciais(p_loja uuid)
returns table (chave text, ambiente text, conta_id uuid, ultima_sincronizacao timestamptz)
language sql security definer set search_path = '' as $$
  select s.decrypted_secret, i.ambiente, i.conta_id, i.ultima_sincronizacao
  from public.integracoes_asaas i
  join vault.decrypted_secrets s on s.id = i.segredo_id
  where i.loja_id = p_loja and i.ativo
$$;

revoke execute on function public.asaas_credenciais from public, anon, authenticated;
grant execute on function public.asaas_credenciais to service_role;
