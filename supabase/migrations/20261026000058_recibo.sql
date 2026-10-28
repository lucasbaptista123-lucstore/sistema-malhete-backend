-- Sistema Malhete — RECIBO do pagamento: o irmão gera de novo o comprovante de qualquer título pago
-- (mensalidade, captação, taxa…), e a Tesouraria imprime para qualquer irmão. Pagamentos = baixas não estornadas.
create function public.recibo_titulo(p_titulo uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  t public.titulos;
  r jsonb;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or t.natureza <> 'receber' or t.irmao_id is null
     or not (public.tem_permissao(t.loja_id, 'tesouraria.ler') or t.irmao_id = public.meu_irmao_id(t.loja_id)) then
    raise exception 'Recibo não disponível';
  end if;
  if t.valor_pago <= 0 then raise exception 'Este título ainda não foi pago'; end if;
  select jsonb_build_object(
    'numero', upper(left(replace(t.id::text, '-', ''), 10)),
    'descricao', t.descricao,
    'competencia', t.competencia,
    'vencimento', t.vencimento,
    'valor', t.valor,
    'valor_pago', t.valor_pago,
    'quitado', t.valor_pago >= t.valor,
    'irmao', jsonb_build_object('nome', i.nome, 'cpf', i.cpf, 'cim', i.cim),
    'loja', jsonb_build_object('nome', trim(l.nome) || coalesce(' nº ' || l.numero, ''), 'cidade', l.cidade, 'uf', l.uf, 'cnpj', l.cnpj),
    'pagamentos', coalesce((
      select jsonb_agg(jsonb_build_object('data', b.data, 'valor', b.valor, 'abatimento', b.abatimento) order by b.data)
      from public.lancamentos b
      where b.titulo_id = t.id and b.estorno_de is null
        and not exists (select 1 from public.lancamentos e where e.estorno_de = b.id)), '[]'::jsonb),
    'tesoureiro', (
      select v.nome from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id join public.irmaos v on v.id = m.irmao_id
      where m.loja_id = t.loja_id and c.codigo = 'tesoureiro' and current_date between m.inicio and m.fim limit 1))
  into r
  from public.irmaos i, public.lojas l
  where i.id = t.irmao_id and l.id = t.loja_id;
  return r;
end $$;
revoke execute on function public.recibo_titulo from public, anon;
grant execute on function public.recibo_titulo to authenticated;
