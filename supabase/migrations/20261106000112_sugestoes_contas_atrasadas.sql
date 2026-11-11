-- "É uma conta" (06/11, caso real: CAPTAÇÃO GOB-SP de 20/09 paga em 06/11 com juros não aparecia).
-- Antes: só contas com vencimento até 45 dias do pagamento. Agora a conta ATRASADA (venceu antes do
-- pagamento) entra sempre, qualquer que seja a idade; a futura continua até 45 dias.
-- Ordem: valor exato; depois o mais perto do valor; no empate, atrasada antes de futura e a atrasada
-- mais antiga primeiro (quem paga com atraso costuma quitar a mais velha).
create or replace function public.sugestoes_para_lancamento(p_lancamento uuid)
returns table (titulo_id uuid, descricao text, vencimento date, saldo numeric, pessoa text, exato boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  l public.lancamentos;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão'; end if;
  return query
  select t.id, t.descricao, t.vencimento, t.valor - t.valor_pago,
         coalesce(i.nome, f.nome), (t.valor - t.valor_pago) = l.valor
  from public.titulos t
  left join public.irmaos i on i.id = t.irmao_id
  left join public.favorecidos f on f.id = t.favorecido_id
  where t.loja_id = l.loja_id and not t.cancelado and t.valor_pago < t.valor
    and t.natureza = case when l.tipo = 'receita' then 'receber' else 'pagar' end
    and t.vencimento <= l.data + 45
  order by ((t.valor - t.valor_pago) = l.valor) desc,
           abs((t.valor - t.valor_pago) - l.valor),
           (t.vencimento > l.data),
           case when t.vencimento <= l.data then t.vencimento end,
           t.vencimento
  limit 12;
end $$;
revoke execute on function public.sugestoes_para_lancamento from public, anon;
grant execute on function public.sugestoes_para_lancamento to authenticated;
