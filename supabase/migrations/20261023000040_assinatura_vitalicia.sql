-- Sistema Malhete — assinatura "vitalícia" (cortesia, sem cobrança e sem prazo). A loja-mãe Orvalho de Hermon
-- nº 2966 (cliente piloto) tem acesso gratuito vitalício, decisão do dono da plataforma em 23/10/2026.
-- A cobrança automática (fase 7) deve ignorar lojas com status 'vitalicia'.

alter table public.assinaturas drop constraint assinaturas_status_check;
alter table public.assinaturas add constraint assinaturas_status_check
  check (status in ('teste', 'ativa', 'atrasada', 'cancelada', 'vitalicia'));
alter table public.assinaturas alter column teste_ate drop not null;

create or replace function public.plataforma_assinatura(p_loja uuid, p_status text, p_plano text default null, p_teste_ate date default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  if p_status not in ('teste', 'ativa', 'atrasada', 'cancelada', 'vitalicia') then raise exception 'Situação inválida'; end if;
  update public.assinaturas
  set status = p_status,
      plano = case when p_status = 'vitalicia' then 'vitalicio' else coalesce(nullif(trim(p_plano), ''), plano) end,
      teste_ate = case when p_status = 'vitalicia' then null else coalesce(p_teste_ate, teste_ate) end
  where loja_id = p_loja;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, depois)
  values (p_loja, 'assinaturas', null, 'plataforma', jsonb_build_object('status', p_status, 'plano', p_plano, 'teste_ate', p_teste_ate));
end $$;

update public.assinaturas set status = 'vitalicia', plano = 'vitalicio', teste_ate = null
where loja_id = '35031580-bc98-4e73-8b64-365080f0a84d';
