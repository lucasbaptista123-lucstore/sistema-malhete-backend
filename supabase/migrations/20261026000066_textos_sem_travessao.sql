-- Sistema Malhete: textos sem travessão (pedido do Lucas): mensagens de WhatsApp, régua, histórico e lançamentos.
-- Funções recriadas a partir do banco com só os textos trocados.
CREATE OR REPLACE FUNCTION private.asaas_espelhar_base(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  integ public.integracoes_asaas;
  t public.titulos;
  v_pid text := p_pg->>'id';
  v_valor numeric(12,2) := (p_pg->>'value')::numeric;
  v_liquido numeric(12,2) := nullif(p_pg->>'netValue', '')::numeric;
  v_status text := p_pg->>'status';
  v_data date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date, current_date);
  v_pessoa record;
  v_cat uuid;
  v_lanc uuid;
  v_res text := 'sem alteração';
  l record;
begin
  select * into integ from public.integracoes_asaas where loja_id = p_loja and ativo;
  if integ.loja_id is null or v_pid is null then
    return 'integração inativa';
  end if;
  perform set_config('malhete.sistema', 'on', true);

  select * into t from public.titulos where loja_id = p_loja and asaas_id = v_pid;
  if t.id is null and (p_pg->>'externalReference') ~ '^[0-9a-f-]{36}$' then
    select * into t from public.titulos
    where loja_id = p_loja and id = (p_pg->>'externalReference')::uuid and natureza = 'receber' and asaas_id is null;
    if t.id is not null then
      update public.titulos set asaas_id = v_pid where id = t.id;
    end if;
  end if;

  -- cobrança nova no Asaas (inclui PIX/TED recebidos) → conta a receber espelhada
  if t.id is null then
    if p_evento in ('PAYMENT_DELETED', 'PAYMENT_REFUNDED', 'PAYMENT_PARTIALLY_REFUNDED', 'PAYMENT_RECEIVED_IN_CASH_UNDONE')
       or coalesce((p_pg->>'deleted')::boolean, false) or v_valor is null or v_valor <= 0 then
      perform set_config('malhete.sistema', 'off', true);
      return 'ignorado (cobrança desconhecida)';
    end if;
    select * into v_pessoa from private.asaas_pessoa(p_loja, p_cliente);
    v_cat := coalesce(integ.categoria_padrao_id,
                      (select id from public.categorias_financeiras where loja_id = p_loja
                       and codigo = case when v_pessoa.irmao_id is not null then 'mensalidades' else 'outras_rec' end));
    insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, favorecido_id, valor, vencimento,
                                competencia, documento, origem, asaas_id)
    values (p_loja, 'receber', coalesce(nullif(trim(p_pg->>'description'), ''), 'Cobrança Asaas'), v_cat,
            v_pessoa.irmao_id, v_pessoa.favorecido_id,
            coalesce(nullif(p_pg->>'originalValue', '')::numeric, v_valor),
            (p_pg->>'dueDate')::date, (p_pg->>'dueDate')::date, v_pid, 'asaas', v_pid)
    returning * into t;
    v_res := 'conta a receber criada';
  end if;

  update public.titulos
  set asaas_link = coalesce(p_pg->>'invoiceUrl', asaas_link), asaas_forma = coalesce(p_pg->>'billingType', asaas_forma),
      asaas_status = coalesce(v_status, asaas_status)
  where id = t.id;

  -- alteração de valor/vencimento no Asaas (só sem baixa)
  if p_evento = 'PAYMENT_UPDATED' and t.valor_pago = 0 and not t.cancelado then
    update public.titulos
    set valor = coalesce(nullif(p_pg->>'originalValue', '')::numeric, v_valor, valor), vencimento = coalesce((p_pg->>'dueDate')::date, vencimento)
    where id = t.id;
    v_res := 'atualizada';
  end if;

  -- recebido com saldo disponível → baixa + tarifa
  if (p_evento = 'PAYMENT_RECEIVED' or (p_evento = 'VARREDURA' and v_status in ('RECEIVED', 'RECEIVED_IN_CASH')))
     and not t.cancelado then
    select * into t from public.titulos where id = t.id;
    if t.valor_pago < t.valor and not exists (
         select 1 from public.lancamentos x where x.titulo_id = t.id and x.documento = v_pid and x.estorno_de is null
           and not exists (select 1 from public.lancamentos s where s.estorno_de = x.id)) then
      v_lanc := private.quitar_titulo(t.id, private.conta_da_baixa(p_loja, v_status, integ.conta_id), v_data, v_valor, v_pid);
      if v_lanc is not null and v_status <> 'RECEIVED_IN_CASH' and v_liquido is not null and v_valor - v_liquido > 0 then
        insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
        values (p_loja, integ.conta_id,
                (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
                'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas: ' || t.descricao, v_pid);
      end if;
      perform private.auto_conciliar(integ.conta_id, v_pid);
      v_res := case when v_status = 'RECEIVED_IN_CASH' then 'baixa (recebido em dinheiro)' else 'baixa automática' end;
    end if;
  end if;

  -- removida no Asaas → cancela aqui (se não houve baixa)
  if p_evento = 'PAYMENT_DELETED' and not t.cancelado then
    if t.valor_pago = 0 then
      update public.titulos set cancelado = true, motivo_cancelamento = 'Cobrança removida no Asaas' where id = t.id;
      v_res := 'cancelada';
    else
      v_res := 'removida no Asaas, mas já tinha baixa, confira';
    end if;
  end if;

  -- estorno/recebimento desfeito → estorna as baixas desse pagamento (e a tarifa)
  if p_evento in ('PAYMENT_REFUNDED', 'PAYMENT_RECEIVED_IN_CASH_UNDONE') then
    for l in select * from public.lancamentos x
             where x.documento = v_pid and x.loja_id = p_loja and x.estorno_de is null
               and not exists (select 1 from public.lancamentos s where s.estorno_de = x.id)
    loop
      insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia,
                                      descricao, irmao_id, favorecido_id, centro_custo_id, titulo_id, abatimento,
                                      estorno_de, motivo_estorno, documento)
      values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, current_date, l.competencia,
              'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.titulo_id, -l.abatimento,
              l.id, 'Estornado no Asaas', v_pid);
    end loop;
    v_res := 'baixa estornada';
  end if;
  if p_evento = 'PAYMENT_PARTIALLY_REFUNDED' then
    v_res := 'estorno parcial no Asaas: ajuste manual na Tesouraria';
  end if;

  perform set_config('malhete.sistema', 'off', true);
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.avisar_cobranca(p_titulo uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t public.titulos;
  v_nome text;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or not public.tem_permissao(t.loja_id, 'tesouraria.editar') then raise exception 'Sem permissão'; end if;
  if t.irmao_id is null or t.asaas_link is null then raise exception 'Esta conta não tem irmão ou link de pagamento'; end if;
  select nome into v_nome from public.irmaos where id = t.irmao_id;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select t.loja_id, t.irmao_id, 'cobranca', t.id,
         format('Olá, %s! Segue o link para pagamento de %s (%s), vencimento %s:%s%s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago), to_char(t.vencimento, 'DD/MM/YYYY'), E'\n', t.asaas_link),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
end $function$;

CREATE OR REPLACE FUNCTION public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
           string_agg(format('• %s: %s%s%s', t.descricao,
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
end $function$;

CREATE OR REPLACE FUNCTION private.aviso_cobranca()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.asaas_link is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Segue o link para pagamento de %s (%s), vencimento %s:%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), E'\n', new.asaas_link));
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.baixar_titulo(p_titulo uuid, p_conta uuid, p_data date DEFAULT CURRENT_DATE, p_abatimento numeric DEFAULT NULL::numeric, p_juros numeric DEFAULT 0, p_desconto numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tit public.titulos;
  v_abat numeric(12,2);
  v_valor numeric(12,2);
  v_id uuid;
begin
  select * into v_tit from public.titulos where id = p_titulo for update;
  if v_tit.id is null then
    raise exception 'Título não encontrado';
  end if;
  if v_tit.cancelado then
    raise exception 'Título cancelado';
  end if;
  if not public.pode_lancar(p_conta)
     or not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = v_tit.loja_id) then
    raise exception 'Sem permissão ou conta inválida';
  end if;
  if v_tit.origem = 'mensalidade' and exists (select 1 from public.contas_financeiras where id = p_conta and tipo = 'tronco') then
    raise exception 'Mensalidade não pode ser recebida no tronco';
  end if;

  v_abat := coalesce(p_abatimento, v_tit.valor - v_tit.valor_pago);
  v_valor := v_abat + coalesce(p_juros, 0) - coalesce(p_desconto, 0);
  if coalesce(p_juros, 0) < 0 or coalesce(p_desconto, 0) < 0 or v_valor <= 0 then
    raise exception 'Valores da baixa inválidos';
  end if;

  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento)
  values (v_tit.loja_id, p_conta, v_tit.categoria_id,
          case v_tit.natureza when 'receber' then 'receita' else 'despesa' end,
          v_valor, coalesce(p_data, current_date), v_tit.competencia,
          v_tit.descricao || case when v_abat < v_tit.valor - v_tit.valor_pago then ' (baixa parcial)' else '' end,
          v_tit.irmao_id, v_tit.favorecido_id, v_tit.centro_custo_id, v_tit.documento, v_tit.id, v_abat)
  returning id into v_id;

  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.concluir_processo(p_processo uuid, p_data date, p_cim text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p public.processos;
  d jsonb;
  v_irmao uuid;
  v_grau smallint;
  v_cim text := nullif(trim(coalesce(p_cim, '')), '');
  v_nasc date;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.gere_processos(p.loja_id) then raise exception 'Sem permissão'; end if;
  if p.etapa <> 'cerimonia' then raise exception 'Registre o placet antes de concluir'; end if;
  if p_data is null or p_data > current_date then raise exception 'Informe a data da cerimônia (não pode ser no futuro)'; end if;
  d := p.dados;
  begin v_nasc := nullif(d->>'data_nascimento', '')::date; exception when others then v_nasc := null; end;
  if p.tipo = 'filiacao' then
    v_cim := coalesce(v_cim, nullif(trim(d->>'cim'), ''));
    if v_cim is null then raise exception 'Informe o CIM do irmão que está se filiando'; end if;
    v_grau := coalesce(nullif(d->>'grau', '')::smallint, 3);
  else
    v_grau := 1;
  end if;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, cpf, cim, email, telefone, data_nascimento, grau, data_iniciacao, endereco, profissao)
  values (p.loja_id, p.nome, nullif(regexp_replace(coalesce(d->>'cpf', ''), '\D', '', 'g'), ''), v_cim,
          coalesce(p.email, nullif(d->>'email', '')), coalesce(p.telefone, nullif(d->>'telefone', '')), v_nasc, v_grau,
          case when p.tipo = 'iniciacao' then p_data else coalesce(nullif(d->>'data_iniciacao', '')::date, p_data) end,
          case when d ? 'endereco' then d->'endereco' end, nullif(d->>'profissao', ''))
  returning id into v_irmao;
  perform set_config('malhete.sistema', 'off', true);
  update public.processos set etapa = 'concluido', irmao_id = v_irmao, data_cerimonia = p_data where id = p.id;
  perform private.evento_processo(p, case p.tipo when 'iniciacao' then 'Iniciado em ' else 'Filiado em ' end || to_char(p_data, 'DD/MM/YYYY')
                                     || '. Incluído no quadro de obreiros');
  return v_irmao;
end $function$;

CREATE OR REPLACE FUNCTION public.encerrar_sindicancia(p_processo uuid, p_seguir boolean, p_obs text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.processos;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Só o Venerável encerra a sindicância'; end if;
  if p.etapa <> 'sindicancia' then raise exception 'O processo não está em sindicância'; end if;
  if p_seguir and exists (select 1 from public.sindicancias where processo_id = p.id and enviado_em is null) then
    raise exception 'Ainda há sindicante sem parecer';
  end if;
  if p_seguir then
    update public.processos set etapa = 'placet' where id = p.id;
    perform private.evento_processo(p, 'Sindicância encerrada, aguardando o placet da Potência' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
  else
    update public.processos set etapa = 'arquivado', motivo_arquivo = coalesce(nullif(trim(p_obs), ''), 'Não aprovado') where id = p.id;
    perform private.evento_processo(p, 'Processo arquivado' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.regua_previa(p_loja uuid, p_mensagem text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_irmao uuid;
  v_tit uuid[];
begin
  if not public.tem_permissao(p_loja, 'tesouraria.ler') then raise exception 'Sem permissão'; end if;
  select t.irmao_id, array_agg(t.id) into v_irmao, v_tit
  from public.titulos t
  where t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor and t.irmao_id is not null
  group by t.irmao_id order by count(*) desc limit 1;
  if v_irmao is null then
    return replace(replace(replace(replace(replace(replace(replace(p_mensagem, '{nome}', 'Carlos'), '{irmao}', 'Carlos André'),
      '{loja}', (select trim(nome) from public.lojas where id = p_loja)), '{itens}', '• Mensalidade 11/2026: R$ 100,00 (venc. 10/11)'),
      '{valor}', 'R$ 100,00'), '{vencimento}', '10/11'), '{link}', 'Ver e pagar: (link)');
  end if;
  return private.regua_texto(p_mensagem, p_loja, v_irmao, v_tit);
end $function$;

CREATE OR REPLACE FUNCTION private.regua_texto(p_modelo text, p_loja uuid, p_irmao uuid, p_titulos uuid[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nome text;
  v_loja text;
  v_itens text;
  v_total numeric;
  v_venc text;
  v_link text;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select nome into v_nome from public.irmaos where id = p_irmao;
  select trim(nome) || coalesce(' nº ' || numero, '') into v_loja from public.lojas where id = p_loja;
  select string_agg(format('• %s: %s (venc. %s)', t.descricao,
                           private.moeda(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
                           to_char(t.vencimento, 'DD/MM')), E'\n' order by t.vencimento),
         sum(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
         string_agg(distinct to_char(t.vencimento, 'DD/MM'), ', '),
         (array_agg(t.asaas_link order by t.vencimento) filter (where t.asaas_link is not null))[1]
    into v_itens, v_total, v_venc, v_link
  from public.titulos t where t.id = any (p_titulos);
  return replace(replace(replace(replace(replace(replace(replace(p_modelo,
    '{nome}', coalesce(private.primeiro_nome(v_nome), 'irmão')),
    '{irmao}', coalesce(v_nome, '')),
    '{loja}', coalesce(v_loja, '')),
    '{itens}', coalesce(v_itens, '')),
    '{valor}', private.moeda(coalesce(v_total, 0))),
    '{vencimento}', coalesce(v_venc, '')),
    '{link}', coalesce('Pagar: ' || v_link, 'Ver e pagar: ' || v_url || '/app/mensalidades'));
end $function$;
