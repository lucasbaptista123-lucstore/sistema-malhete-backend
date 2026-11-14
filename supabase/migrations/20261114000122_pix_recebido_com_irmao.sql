-- Sistema Malhete: "É do Tronco" e "É uma conta" também para PIX recebido de irmão IDENTIFICADO (14/11). Na sessão
-- de 13/11, 5 irmãos com CPF pagaram o Tronco digitando a chave; o Asaas os identificou e a conta automática ("Cobrança
-- gerada automaticamente a partir de Pix recebido") ficou com o nome do irmão. A regra exigia pagador sem cadastro, e o
-- "É do Tronco" recusava ("não é um PIX sem dono"). Agora vale para os dois casos; ao virar Tronco, o recebimento antigo,
-- o estorno e a conta automática perdem o nome (o Tronco é anônimo; validar_lancamento ganha a exceção 'malhete.anonimizar',
-- que só deixa APAGAR irmão/favorecido, nada mais). Confirmar no Tronco prefere o PIX do próprio irmão.

CREATE OR REPLACE FUNCTION public.validar_lancamento()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_orig public.lancamentos;
  v_tit public.titulos;
  v_tipo text;
begin
  -- única alteração permitida: trocar a categoria (pela função reclassificar_lancamento)
  if tg_op = 'UPDATE' and current_setting('malhete.reclassificar', true) = 'on'
     and (to_jsonb(new) - 'categoria_id') = (to_jsonb(old) - 'categoria_id') then
    if new.categoria_id is not null and not exists (
         select 1 from public.categorias_financeiras where id = new.categoria_id and loja_id = new.loja_id and tipo = new.tipo) then
      raise exception 'Categoria não pertence à loja ou não é do tipo do lançamento';
    end if;
    return new;
  end if;
  -- Tronco é anônimo (0122): ao virar Tronco, o recebimento antigo e o estorno só podem PERDER o nome do pagador
  if tg_op = 'UPDATE' and current_setting('malhete.anonimizar', true) = 'on'
     and new.irmao_id is null and new.favorecido_id is null
     and (to_jsonb(new) - 'irmao_id' - 'favorecido_id') = (to_jsonb(old) - 'irmao_id' - 'favorecido_id') then
    return new;
  end if;
  if tg_op <> 'INSERT' then
    raise exception 'Lançamento não pode ser alterado nem apagado; use o estorno';
  end if;

  new.competencia := coalesce(new.competencia, new.data);

  if not exists (select 1 from public.contas_financeiras where id = new.conta_id and loja_id = new.loja_id)
     or (new.conta_destino_id is not null and not exists (
           select 1 from public.contas_financeiras where id = new.conta_destino_id and loja_id = new.loja_id)) then
    raise exception 'Conta não pertence à loja';
  end if;
  if new.categoria_id is not null and not exists (
       select 1 from public.categorias_financeiras
       where id = new.categoria_id and loja_id = new.loja_id and tipo = new.tipo) then
    raise exception 'Categoria não pertence à loja ou não é do tipo do lançamento';
  end if;
  if new.irmao_id is not null and not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Irmão não pertence à loja';
  end if;
  if new.favorecido_id is not null and not exists (select 1 from public.favorecidos where id = new.favorecido_id and loja_id = new.loja_id) then
    raise exception 'Fornecedor/cliente não pertence à loja';
  end if;
  if new.centro_custo_id is not null and not exists (select 1 from public.centros_custo where id = new.centro_custo_id and loja_id = new.loja_id) then
    raise exception 'Centro de custo não pertence à loja';
  end if;

  if new.estorno_de is not null then
    select * into v_orig from public.lancamentos where id = new.estorno_de;
    if v_orig.id is null or v_orig.estorno_de is not null
       or v_orig.loja_id <> new.loja_id or v_orig.conta_id <> new.conta_id
       or v_orig.conta_destino_id is distinct from new.conta_destino_id
       or v_orig.categoria_id is distinct from new.categoria_id
       or v_orig.titulo_id is distinct from new.titulo_id
       or v_orig.abatimento is distinct from -new.abatimento
       or v_orig.tipo <> new.tipo or new.valor <> -v_orig.valor then
      raise exception 'Estorno não confere com o lançamento original';
    end if;
  elsif new.titulo_id is not null then
    select * into v_tit from public.titulos where id = new.titulo_id;
    if v_tit.id is null or v_tit.loja_id <> new.loja_id or v_tit.cancelado then
      raise exception 'Título inválido ou cancelado';
    end if;
    v_tipo := case v_tit.natureza when 'receber' then 'receita' else 'despesa' end;
    if new.tipo <> v_tipo or new.categoria_id is distinct from v_tit.categoria_id then
      raise exception 'Baixa não confere com o título';
    end if;
    if new.abatimento <= 0 or new.abatimento > v_tit.valor - v_tit.valor_pago then
      raise exception 'Valor da baixa maior que o saldo do título';
    end if;
  end if;

  new.criado_por := auth.uid();
  new.criado_em := now();
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.conta_automatica_de_pix(p_lancamento uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select t.id from public.lancamentos l join public.titulos t on t.id = l.titulo_id
  where l.id = p_lancamento and t.origem = 'asaas' and t.natureza = 'receber' and not t.cancelado
    and coalesce(t.asaas_forma, 'PIX') = 'PIX'
    and t.descricao ilike 'Cobrança gerada automaticamente a partir de Pix%'
    and t.valor_pago = coalesce(l.abatimento, l.valor)
    and not exists (select 1 from public.lancamentos o where o.titulo_id = t.id and o.id <> l.id)
$function$;

CREATE OR REPLACE FUNCTION private.tronco_do_lancamento(p_lancamento uuid, p_contrib uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_auto uuid;
  v_novo uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento for update;
  if not private.pix_sem_dono(l.id) then raise exception 'Este lançamento não é um PIX sem dono no Asaas'; end if;
  v_auto := private.conta_automatica_de_pix(l.id);
  perform set_config('malhete.sem_avisos', 'on', true);
  -- tira o recebimento como estava (estorno idêntico; a baixa da conta automática sai junto) …
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento,
                                  estorno_de, motivo_estorno)
  values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, l.data, l.competencia,
          'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.documento,
          l.titulo_id, case when l.titulo_id is not null then -l.abatimento end, l.id,
          'É do Tronco de Beneficência');
  -- … e lança o Tronco com o mesmo valor, data, conta e documento, sem nome
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
  values (l.loja_id, l.conta_id, (select id from public.categorias_financeiras where loja_id = l.loja_id and codigo = 'tronco'),
          'receita', l.valor, l.data, l.data, 'Tronco de Beneficência (PIX)', l.documento)
  returning id into v_novo;
  update public.extrato_itens set lancamento_id = v_novo, motivo = 'Tronco de Beneficência' where lancamento_id = l.id;
  if v_auto is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set cancelado = true, motivo_cancelamento = 'PIX recebido era do Tronco de Beneficência'
    where id = v_auto;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  -- Tronco é anônimo: o recebimento antigo, o estorno e a conta automática deixam de mostrar quem pagou
  perform set_config('malhete.anonimizar', 'on', true);
  update public.lancamentos set irmao_id = null, favorecido_id = null
  where (id = l.id or (estorno_de = l.id and loja_id = l.loja_id)) and (irmao_id is not null or favorecido_id is not null);
  perform set_config('malhete.anonimizar', 'off', true);
  if v_auto is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set irmao_id = null, favorecido_id = null where id = v_auto;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  if p_contrib is not null then
    update public.tronco_contribuicoes
    set status = 'confirmada', decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_novo
    where id = p_contrib and status <> 'confirmada';
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_novo;
end $$;

CREATE OR REPLACE FUNCTION public.decidir_tronco(p_id uuid, p_confirmar boolean, p_data date DEFAULT CURRENT_DATE)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.tronco_contribuicoes;
  v_conta uuid;
  v_lanc uuid;
  v_pix uuid;
begin
  select * into c from public.tronco_contribuicoes where id = p_id for update;
  if c.id is null or not public.tem_permissao(c.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro confirma o Tronco'; end if;
  if c.status = 'confirmada' then raise exception 'Já confirmada'; end if;
  if p_confirmar then
    -- o PIX já entrou pelo Asaas sem ser reconhecido: o mais antigo com o mesmo valor, de um dia antes a 5 dias depois
    -- prefere o PIX do próprio irmão da contribuição (pagador identificado pelo CPF), depois o mais antigo
    select l.id into v_pix from public.lancamentos l
    left join public.titulos t on t.id = l.titulo_id
    where l.loja_id = c.loja_id and l.tipo = 'receita' and l.valor = c.valor
      and l.data between c.informado_em::date - 1 and c.informado_em::date + 5
      and private.pix_sem_dono(l.id)
    order by (t.irmao_id is not distinct from c.irmao_id) desc, l.data, l.criado_em limit 1;
    if v_pix is not null then
      perform private.tronco_do_lancamento(v_pix, c.id);
      return;
    end if;
    if (private.tronco_pix_dados(c.loja_id)->>'automatico')::boolean then
      raise exception 'Não achei um PIX de % no Asaas. Se o irmão pagou agora, espere aparecer em Movimentações; se deu em dinheiro, lance em Dinheiro do saco.', private.moeda(c.valor);
    end if;
    select id into v_conta from public.contas_financeiras where loja_id = c.loja_id and tipo = 'tronco' and ativa limit 1;
    if v_conta is null then raise exception 'A loja não tem conta Tronco ativa'; end if;
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao, documento)
    values (c.loja_id, v_conta,
            (select id from public.categorias_financeiras where loja_id = c.loja_id and codigo = 'tronco'),
            'receita', c.valor, coalesce(p_data, current_date), 'Tronco de Beneficência (PIX)', c.txid)
    returning id into v_lanc;
  end if;
  update public.tronco_contribuicoes
  set status = case when p_confirmar then 'confirmada' else 'nao_localizada' end,
      decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_lanc
  where id = c.id;
end $function$;

CREATE OR REPLACE FUNCTION public.tronco_e_do_tronco(p_lancamento uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_contrib uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.tem_permissao(l.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro lança o Tronco'; end if;
  -- a contribuição aguardando do mesmo valor; se o pagador foi identificado, a dele primeiro
  select c.id into v_contrib from public.tronco_contribuicoes c
  where c.loja_id = l.loja_id and c.status in ('aguardando', 'informada') and c.valor = l.valor
    and c.informado_em::date between l.data - 5 and l.data + 1
  order by (c.irmao_id is not distinct from (select t.irmao_id from public.titulos t where t.id = l.titulo_id)) desc,
           (c.status = 'informada') desc, c.informado_em
  limit 1;
  return private.tronco_do_lancamento(l.id, v_contrib);
end $$;
