-- Irmão sem CPF (09/11, pedido do Lucas: "o sistema gera o PIX copia e cola e não precisa gerar cobrança no
-- Asaas; só precisa identificar quem fez o PIX"). Sem CPF o Asaas não cria cobrança, e então:
--   * o aviso de cobrança nova nem saía (só saía quando a cobrança do Asaas ficava pronta);
--   * "Enviar cobrança" recusava ("não tem link de pagamento");
--   * o aviso ia sem os botões de pagar.
-- Agora, com a chave PIX da Tesouraria preenchida, a conta sem cobrança no Asaas também é avisada, com os
-- botões; "Pagar com PIX" responde com o copia e cola da chave da Loja no valor atualizado (com multa e juros
-- se atrasada). A baixa vem pela identificação do PIX recebido (private.pix_irmao: CPF, cliente do Asaas ou
-- nome) e, reconhecido pelo nome, o CPF de quem pagou fica no cadastro (da próxima vez sai cobrança do Asaas).

-- a Loja tem chave PIX própria para receber
create or replace function private.tem_pix_chave(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tesouraria_config where loja_id = p_loja and nullif(trim(pix_chave), '') is not null)
$$;
revoke execute on function private.tem_pix_chave from public, anon, authenticated;

-- esta conta vai virar cobrança no Asaas? (integração criando cobranças e irmão com CPF/CNPJ)
create or replace function private.vira_cobranca_asaas(p_loja uuid, p_irmao uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.integracoes_asaas g where g.loja_id = p_loja and g.ativo and g.criar_cobrancas)
     and exists (select 1 from public.irmaos i where i.id = p_irmao
                 and length(regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g')) in (11, 14))
$$;
revoke execute on function private.vira_cobranca_asaas from public, anon, authenticated;

create or replace function private.notificar_pix(p_loja uuid, p_irmao uuid, p_tipo text, p_titulos uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tok text; v_ids uuid[]; v_chave boolean := private.tem_pix_chave(p_loja);
begin
  select array_agg(id order by vencimento) into v_ids from public.titulos
  where id = any (p_titulos) and not cancelado and valor_pago < valor and natureza = 'receber'
    and (asaas_id is not null or v_chave);
  if v_ids is null then return; end if;
  select id, token into v_id, v_tok from public.notificacoes
  where loja_id = p_loja and irmao_id = p_irmao and tipo = p_tipo and criado_em = now() and botoes is null
  order by id limit 1;
  if v_id is null then return; end if;
  update public.notificacoes
  set botoes = array['Pagar com PIX|pag:pix:' || v_tok, 'Pagar pelo Malhete|pag:app:' || v_tok],
      titulos = v_ids
  where id = v_id;
end $$;
revoke execute on function private.notificar_pix from public, anon, authenticated;

create or replace function private.aviso_cobranca() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if new.asaas_link is null then
    -- sem cobrança no Asaas: avisa na criação só se ela não vier (sem CPF ou sem integração) e houver chave PIX
    if tg_op <> 'INSERT' or new.origem = 'asaas' or private.vira_cobranca_asaas(new.loja_id, new.irmao_id)
       or not private.tem_pix_chave(new.loja_id) then
      return new;
    end if;
  elsif tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then
    return new;
  end if;
  -- cobrança criada direto no Asaas (o próprio Asaas já avisa) ou já paga lá, aguardando compensação: não avisa
  if new.origem = 'asaas' or coalesce(new.asaas_status, '') in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH') then return new; end if;
  -- gerou o ano todo de uma vez: só avisa na criação o que vence nos próximos 20 dias; o resto a régua lembra perto do vencimento
  if new.vencimento > current_date + 20 then return new; end if;
  -- já avisada (ex.: avisada pela chave e depois ganhou cobrança no Asaas)
  if exists (select 1 from public.notificacoes where referencia = new.id and tipo = 'cobranca') then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), '', ''));
  perform private.notificar_pix(new.loja_id, new.irmao_id, 'cobranca', array[new.id]);
  return new;
end $$;

create or replace function public.avisar_cobranca(p_titulo uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t public.titulos;
  v_nome text;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or not public.tem_permissao(t.loja_id, 'tesouraria.editar') then raise exception 'Sem permissão'; end if;
  if t.irmao_id is null then raise exception 'Esta conta não é de um irmão'; end if;
  if t.asaas_link is null and not private.tem_pix_chave(t.loja_id) then
    raise exception 'Esta conta não tem link de pagamento. Preencha a chave PIX da Loja em Tesouraria, Configurações';
  end if;
  select nome into v_nome from public.irmaos where id = t.irmao_id;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select t.loja_id, t.irmao_id, 'cobranca', t.id,
         format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago + case when t.vencimento < current_date
                              then private.encargos(t.loja_id, t.valor - t.valor_pago, t.vencimento) else 0 end),
                to_char(t.vencimento, 'DD/MM/YYYY'), '', ''),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
  perform private.notificar_pix(t.loja_id, t.irmao_id, 'cobranca', array[t.id]);
end $$;

-- botão "Pagar com PIX": devolve também o valor atualizado e a chave da Loja (para o copia e cola sem Asaas)
create or replace function public.whatsapp_pagamento(p_loja uuid, p_telefone text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n public.notificacoes;
begin
  select * into n from public.notificacoes where loja_id = p_loja and token = p_token and botoes is not null;
  if n.id is null or public.tel_chave(p_telefone) is distinct from public.tel_chave(n.telefone) then return null; end if;
  return jsonb_build_object('link', private.link_mensalidades(),
    'chave', (select nullif(trim(pix_chave), '') from public.tesouraria_config where loja_id = p_loja),
    'titular', (select coalesce(nullif(trim(c.pix_titular), ''), l.nome) from public.lojas l
                left join public.tesouraria_config c on c.loja_id = l.id where l.id = p_loja),
    'cidade', (select cidade from public.lojas where id = p_loja),
    'titulos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'asaas_id', t.asaas_id, 'pix', t.pix_copia_cola,
                        'descricao', t.descricao, 'valor', t.valor - t.valor_pago,
                        'atualizado', t.valor - t.valor_pago + case when t.vencimento < current_date
                                        then private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento) else 0 end)
                        order by t.vencimento), '[]')
                from public.titulos t where t.id = any (n.titulos) and not t.cancelado and t.valor_pago < t.valor));
end $$;

-- reconhecido pelo nome: grava o CPF de quem pagou (se ninguém da Loja usa esse CPF)
create or replace function private.gravar_cpf_do_pagador(p_irmao uuid, p_cliente jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_doc text := nullif(regexp_replace(coalesce(p_cliente->>'cpfCnpj', ''), '\D', '', 'g'), '');
begin
  if v_doc is null or length(v_doc) <> 11 then return; end if;
  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos i set cpf = v_doc
   where i.id = p_irmao and nullif(regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g'), '') is null
     and not exists (select 1 from public.irmaos o where o.loja_id = i.loja_id and o.id <> i.id
                     and regexp_replace(coalesce(o.cpf, ''), '\D', '', 'g') = v_doc);
end $$;
revoke execute on function private.gravar_cpf_do_pagador from public, anon, authenticated;

-- asaas_pessoa e pix_irmao: depois de achar pelo nome, gravam o CPF (troca mínima: embrulho)
create or replace function private.irmao_pelo_nome_e_cpf(p_loja uuid, p_cliente jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_doc text := nullif(regexp_replace(coalesce(p_cliente->>'cpfCnpj', ''), '\D', '', 'g'), '');
  v uuid := private.irmao_pelo_nome(p_loja, p_cliente->>'name', v_doc);
begin
  if v is not null then perform private.gravar_cpf_do_pagador(v, p_cliente); end if;
  return v;
end $$;
revoke execute on function private.irmao_pelo_nome_e_cpf from public, anon, authenticated;

do $$
declare d text;
begin
  -- troca a chamada do nome nas duas funções da 0115 pela versão que também grava o CPF
  select pg_get_functiondef('private.asaas_pessoa'::regproc) into d;
  if position('private.irmao_pelo_nome(p_loja, p_cliente->>''name'', v_doc)' in d) = 0 then
    raise exception 'asaas_pessoa não está na versão da 0115';
  end if;
  execute replace(d, 'private.irmao_pelo_nome(p_loja, p_cliente->>''name'', v_doc)', 'private.irmao_pelo_nome_e_cpf(p_loja, p_cliente)');
  select pg_get_functiondef('private.pix_irmao'::regproc) into d;
  if position('private.irmao_pelo_nome(p_loja, p_cliente->>''name'', v_doc)' in d) = 0 then
    raise exception 'pix_irmao não está na versão da 0115';
  end if;
  execute replace(d, 'private.irmao_pelo_nome(p_loja, p_cliente->>''name'', v_doc)', 'private.irmao_pelo_nome_e_cpf(p_loja, p_cliente)');
end $$;
