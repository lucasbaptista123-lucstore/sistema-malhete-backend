-- Sistema Malhete — encargos por atraso (multa % única + juros % ao mês, pro rata dia), definidos pela Tesouraria.
-- Manual: o sistema mostra o valor atualizado e sugere os juros na baixa. Com Asaas: as cobranças novas vão com
-- a mesma multa/juros e o Asaas calcula. Também: chave PIX própria do Tronco (opcional).

alter table public.tesouraria_config
  add column multa_percentual numeric(5,2) not null default 0 check (multa_percentual between 0 and 20),
  add column juros_mensal numeric(5,2) not null default 0 check (juros_mensal between 0 and 10),
  add column pix_tronco_chave text,
  add column pix_tronco_titular text;

-- encargos de um saldo vencido, pela configuração da loja
create function private.encargos(p_loja uuid, p_saldo numeric, p_vencimento date) returns numeric
language sql stable security definer set search_path = '' as $$
  select case when p_vencimento >= current_date or p_saldo <= 0 then 0
    else round(p_saldo * coalesce(c.multa_percentual, 0) / 100
               + p_saldo * coalesce(c.juros_mensal, 0) / 100 / 30 * (current_date - p_vencimento), 2) end
  from (select 1) x left join public.tesouraria_config c on c.loja_id = p_loja
$$;

-- aviso de pendências mostra o valor atualizado das vencidas
create or replace function public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_txt text;
  v_tel text;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro envia avisos de mensalidade'; end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;
  for r in
    select i.id, i.nome, i.telefone,
           coalesce(sum(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento))
                    filter (where t.valor_pago < t.valor), 0) as aberto,
           count(*) filter (where t.valor_pago < t.valor and t.vencimento < current_date and t.origem = 'mensalidade') as atrasados,
           string_agg(format('• %s — %s%s%s', t.descricao,
                             private.moeda(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
                             case when t.vencimento < current_date then ' (vencida em ' || to_char(t.vencimento, 'DD/MM')
                                    || case when private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento) > 0
                                            then ', com multa e juros' else '' end || ')'
                                  else ' (vence ' || to_char(t.vencimento, 'DD/MM') || ')' end,
                             coalesce(E'\n  ' || t.asaas_link, '')),
                      E'\n' order by t.vencimento) filter (where t.valor_pago < t.valor) as itens
    from public.irmaos i
    left join public.titulos t on t.irmao_id = i.id and t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado
    where i.loja_id = p_loja and i.id = any (p_irmaos)
    group by i.id, i.nome, i.telefone
  loop
    v_txt := replace(replace(replace(trim(p_mensagem),
               '{nome}', private.primeiro_nome(r.nome)),
               '{valor}', private.moeda(r.aberto)),
               '{meses}', r.atrasados::text);
    if r.itens is not null then v_txt := v_txt || E'\n\nPendências:\n' || r.itens; end if;
    v_tel := nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '');
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (p_loja, r.id, 'debito', null, v_txt, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- a edge function do Asaas lê multa/juros ao criar a cobrança
create function public.asaas_encargos(p_loja uuid) returns table (multa numeric, juros numeric)
language sql stable security definer set search_path = '' as $$
  select coalesce(c.multa_percentual, 0), coalesce(c.juros_mensal, 0)
  from (select 1) x left join public.tesouraria_config c on c.loja_id = p_loja
$$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.asaas_encargos from public, anon, authenticated;
grant execute on function public.asaas_encargos to service_role;
