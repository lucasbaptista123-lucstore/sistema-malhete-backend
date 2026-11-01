-- Tronco de Beneficência ANÔNIMO para a Tesouraria (31/10, pedido do Lucas; o Tronco é sigiloso por tradição).
-- A Tesouraria confere valor, data e identificação do PIX, nunca QUEM contribuiu:
--  1) a coluna irmao_id de tronco_contribuicoes deixa de ser legível pelo app (privilégio por coluna);
--     o irmão continua vendo as próprias contribuições (a política filtra pelo dono, sem expor a coluna);
--  2) lançamento de receita na conta do Tronco nunca guarda o irmão (gatilho), e os antigos são limpos.
-- O agradecimento ao irmão continua (as funções do sistema leem o irmão por dentro, com privilégio próprio).
revoke select on public.tronco_contribuicoes from authenticated, anon;
grant select (id, loja_id, valor, txid, status, informado_em, decidido_por, decidido_em, lancamento_id, origem, asaas_id)
  on public.tronco_contribuicoes to authenticated;

create function private.tronco_sem_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.tipo = 'receita' and exists (select 1 from public.contas_financeiras c where c.id = new.conta_id and c.tipo = 'tronco') then
    new.irmao_id := null;
  end if;
  return new;
end $$;
create trigger zz_tronco_anonimo before insert or update on public.lancamentos for each row execute function private.tronco_sem_irmao();

select set_config('malhete.sistema', 'on', true);
update public.lancamentos l set irmao_id = null
from public.contas_financeiras c
where c.id = l.conta_id and c.tipo = 'tronco' and l.tipo = 'receita' and l.irmao_id is not null;
