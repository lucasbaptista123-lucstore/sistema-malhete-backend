-- Sistema Malhete: TRONCO DA SESSÃO (12/11, ideia do Lucas). No dia da sessão o Tesoureiro vê os presentes,
-- escolhe quem recebe e manda pelo WhatsApp (agora ou num horário marcado) o convite para o Tronco: botões com os
-- valores sugeridos da Loja e "Outro valor" (página sem login, /tronco/<token>). O irmão escolhe o valor e recebe o
-- PIX copia e cola na chave da Loja (sem taxa). O reconhecimento é o de sempre: com Asaas, pelo CPF do pagador e o
-- valor (private.pix_irmao); sem Asaas, o irmão toca "Já paguei" e o Tesoureiro confere. Ninguém vê quem deu quanto:
-- a tela do Tesoureiro mostra só o total da sessão. O dinheiro do saco entra no mesmo total.

-- 1) valores sugeridos (o Tesoureiro põe e tira; no WhatsApp vão os dois primeiros + "Outro valor")
alter table public.tesouraria_config
  add column tronco_valores numeric(12,2)[] not null default '{20,50}',
  add constraint tronco_valores_ok check (cardinality(tronco_valores) <= 6 and 0 < all (tronco_valores));

-- 2) fila do WhatsApp: tipo 'tronco', envio agendado (enviar_apos) e cancelado
alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check check (tipo = any (array[
  'cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema', 'justificativa',
  'evento', 'documento', 'tronco']));
alter table public.notificacoes drop constraint notificacoes_status_check;
alter table public.notificacoes add constraint notificacoes_status_check check (status = any (array[
  'pendente', 'enviado', 'sem_telefone', 'falhou', 'descartado', 'cancelado']));
alter table public.notificacoes add column enviar_apos timestamptz;

CREATE OR REPLACE FUNCTION public.notificacoes_proximas(p_por_loja integer DEFAULT 2)
 RETURNS TABLE(id uuid, loja_id uuid, telefone text, mensagem text, botoes text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.notificacoes set status = 'descartado', erro = 'WhatsApp desconectado por mais de 3 dias'
  where status = 'pendente' and coalesce(enviar_apos, criado_em) < now() - interval '3 days'
    and not exists (select 1 from public.integracoes_whatsapp w where w.loja_id = notificacoes.loja_id and w.status = 'conectado');
  return query
  select x.id, x.loja_id, x.telefone, x.mensagem, x.botoes from (
    select n.*, row_number() over (partition by n.loja_id order by coalesce(n.enviar_apos, n.criado_em)) as k
    from public.notificacoes n
    join public.integracoes_whatsapp w on w.loja_id = n.loja_id and w.status = 'conectado'
    where n.status = 'pendente'
      and (n.enviar_apos is null or n.enviar_apos <= now())
      and not exists (select 1 from public.notificacoes e where e.loja_id = n.loja_id and e.status = 'enviado'
                      and e.enviado_em > now() - interval '25 seconds')
      and (select count(*) from public.notificacoes e where e.loja_id = n.loja_id and e.status = 'enviado'
           and e.enviado_em > now() - interval '24 hours') < 60
  ) x where x.k <= least(greatest(p_por_loja, 1), 2);
end $function$;

-- 3) a sessão do Tronco (agendamento e dinheiro do saco) e os convites (um por irmão por sessão)
create table public.tronco_sessoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sessao_id uuid not null unique references public.sessoes(id) on delete cascade,
  agendado_para timestamptz,
  dinheiro numeric(12,2) check (dinheiro >= 0),
  dinheiro_lancamento_id uuid references public.lancamentos(id),
  criado_por uuid references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.tronco_sessoes (loja_id);
create index on public.tronco_sessoes (dinheiro_lancamento_id);
create index on public.tronco_sessoes (criado_por);
alter table public.tronco_sessoes enable row level security;
-- leitura pela Tesouraria; gravação só pelas funções
create policy le on public.tronco_sessoes for select to authenticated
  using ((select public.tem_permissao(loja_id, 'tronco.editar')) or (select public.tem_permissao(loja_id, 'tesouraria.ler')));
create trigger auditoria after insert or update or delete on public.tronco_sessoes for each row execute function public.registrar_auditoria();

create table public.tronco_convites (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tronco_sessao_id uuid not null references public.tronco_sessoes(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  notificacao_id uuid references public.notificacoes(id) on delete set null,
  criado_em timestamptz not null default now(),
  unique (tronco_sessao_id, irmao_id)
);
create index on public.tronco_convites (loja_id);
create index on public.tronco_convites (irmao_id);
create index on public.tronco_convites (notificacao_id);
-- sem política: o app não lê convites (o token é a chave da página do irmão); tudo passa pelas funções
alter table public.tronco_convites enable row level security;

alter table public.tronco_contribuicoes add column tronco_sessao_id uuid references public.tronco_sessoes(id) on delete set null;
create index on public.tronco_contribuicoes (tronco_sessao_id);
grant select (tronco_sessao_id) on public.tronco_contribuicoes to authenticated;

-- 4) apoio
create function private.link_app(p_caminho text) returns text
language sql stable security definer set search_path = '' as $$
  -- app_url_teste (só no ambiente de teste) aponta para a pré-visualização, onde o código novo roda
  select coalesce((select valor from public.config_plataforma where chave = 'app_url_teste'),
                  (select valor from public.config_plataforma where chave = 'app_url'), '') || p_caminho
$$;
revoke execute on function private.link_app from public, anon, authenticated;

create function private.valor_curto(v numeric) returns text
language sql immutable set search_path = '' as $$
  select case when v = trunc(v) then 'R$ ' || trunc(v)::bigint::text else private.moeda(v) end
$$;

/** Chave, titular e cidade do PIX do Tronco (chave própria do Tronco, se houver) e se o Asaas reconhece sozinho. */
create function private.tronco_pix_dados(p_loja uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'chave', coalesce(nullif(trim(c.pix_tronco_chave), ''), nullif(trim(c.pix_chave), '')),
    'titular', coalesce(nullif(trim(c.pix_tronco_titular), ''), nullif(trim(c.pix_titular), ''), l.nome),
    'cidade', l.cidade,
    -- com chave própria do Tronco o PIX cai fora do Asaas: o Tesoureiro confere
    'automatico', nullif(trim(c.pix_tronco_chave), '') is null
                  and exists (select 1 from public.integracoes_asaas a where a.loja_id = l.id and a.ativo),
    'valores', coalesce(c.tronco_valores, '{20,50}'))
  from public.lojas l left join public.tesouraria_config c on c.loja_id = l.id
  where l.id = p_loja
$$;
revoke execute on function private.tronco_pix_dados from public, anon, authenticated;

/** Contribuição "aguardando" do convite com o valor escolhido (toque repetido no mesmo valor não duplica). */
create function private.tronco_contribuir(p_convite public.tronco_convites, p_valor numeric)
returns public.tronco_contribuicoes
language plpgsql security definer set search_path = '' as $$
declare
  v numeric(12,2) := round(p_valor, 2);
  c public.tronco_contribuicoes;
begin
  if v is null or v <= 0 or v > 100000 then raise exception 'Valor inválido'; end if;
  select * into c from public.tronco_contribuicoes
  where tronco_sessao_id = p_convite.tronco_sessao_id and irmao_id = p_convite.irmao_id
    and status = 'aguardando' and valor = v and informado_em > now() - interval '2 days'
  order by informado_em desc limit 1;
  if c.id is not null then return c; end if;
  if (select count(*) from public.tronco_contribuicoes
      where tronco_sessao_id = p_convite.tronco_sessao_id and irmao_id = p_convite.irmao_id) >= 10 then
    raise exception 'Limite de contribuições por este convite';
  end if;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem, tronco_sessao_id)
  values (p_convite.loja_id, p_convite.irmao_id, v, 'TRONCO' || upper(substr(md5(random()::text), 1, 6)),
          'aguardando', 'pix_chave', p_convite.tronco_sessao_id)
  returning * into c;
  return c;
end $$;
revoke execute on function private.tronco_contribuir from public, anon, authenticated;

create function private.tronco_convite_valido(p_token text) returns public.tronco_convites
language sql stable security definer set search_path = '' as $$
  -- vale até 7 dias depois da sessão
  select c.* from public.tronco_convites c
  join public.tronco_sessoes ts on ts.id = c.tronco_sessao_id
  join public.sessoes s on s.id = ts.sessao_id
  where c.token = p_token and s.data >= current_date - 7
$$;
revoke execute on function private.tronco_convite_valido from public, anon, authenticated;

-- 5) Tesoureiro: valores sugeridos
create function public.tronco_definir_valores(p_loja uuid, p_valores numeric[]) returns numeric[]
language plpgsql security definer set search_path = '' as $$
declare v numeric(12,2)[];
begin
  if not public.tem_permissao(p_loja, 'tronco.editar') then raise exception 'Só o Tesoureiro define os valores do Tronco'; end if;
  select coalesce(array_agg(x order by ord), '{}') into v from (
    select round(x, 2) x, min(ord) ord from unnest(p_valores) with ordinality u(x, ord)
    where x > 0 and x <= 100000 group by round(x, 2)) t;
  if cardinality(v) = 0 then raise exception 'Deixe pelo menos um valor'; end if;
  if cardinality(v) > 6 then raise exception 'No máximo 6 valores'; end if;
  insert into public.tesouraria_config (loja_id, tronco_valores) values (p_loja, v)
  on conflict (loja_id) do update set tronco_valores = excluded.tronco_valores, atualizado_em = now();
  return v;
end $$;
revoke execute on function public.tronco_definir_valores from public, anon;
grant execute on function public.tronco_definir_valores to authenticated;

-- 6) Tesoureiro: a sessão (presentes, quem já recebeu, totais sem nomes)
create function public.tronco_da_sessao(p_sessao uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.sessoes;
  ts public.tronco_sessoes;
begin
  select * into s from public.sessoes where id = p_sessao;
  if s.id is null or not (public.tem_permissao(s.loja_id, 'tronco.editar') or public.tem_permissao(s.loja_id, 'tesouraria.ler')) then
    raise exception 'Sem acesso ao Tronco';
  end if;
  select * into ts from public.tronco_sessoes where sessao_id = s.id;
  return jsonb_build_object(
    'presenca_registrada', exists (select 1 from public.presencas p where p.sessao_id = s.id),
    'agendado_para', ts.agendado_para,
    'dinheiro', ts.dinheiro,
    'dinheiro_lancado', ts.dinheiro_lancamento_id is not null
      and not exists (select 1 from public.lancamentos e where e.estorno_de = ts.dinheiro_lancamento_id),
    'pix', private.tronco_pix_dados(s.loja_id) - 'chave' - 'titular' - 'cidade'
           || jsonb_build_object('tem_chave', (private.tronco_pix_dados(s.loja_id)->>'chave') is not null),
    'irmaos', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'nome', i.nome, 'grau', i.grau,
        'tem_telefone', nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is not null,
        'presente', exists (select 1 from public.presencas p where p.sessao_id = s.id and p.irmao_id = i.id and p.situacao = 'presente'),
        'confirmou', exists (select 1 from public.confirmacoes f where f.sessao_id = s.id and f.irmao_id = i.id and f.resposta = 'vou'),
        'envio', (select jsonb_build_object('status', n.status, 'enviado_em', n.enviado_em, 'enviar_apos', n.enviar_apos)
                  from public.tronco_convites c left join public.notificacoes n on n.id = c.notificacao_id
                  where c.tronco_sessao_id = ts.id and c.irmao_id = i.id)
      ) order by i.nome), '[]')
      from public.irmaos i where i.loja_id = s.loja_id and i.situacao in ('ativo', 'licenciado')),
    -- só totais: quem deu quanto não aparece
    'recebido', (select jsonb_build_object('valor', coalesce(sum(valor), 0), 'quantidade', count(*))
                 from public.tronco_contribuicoes where tronco_sessao_id = ts.id and status = 'confirmada'),
    'aguardando', (select jsonb_build_object('valor', coalesce(sum(valor), 0), 'quantidade', count(*))
                   from public.tronco_contribuicoes where tronco_sessao_id = ts.id and status in ('aguardando', 'informada')),
    'informadas', (select count(*) from public.tronco_contribuicoes where tronco_sessao_id = ts.id and status = 'informada'));
end $$;
revoke execute on function public.tronco_da_sessao from public, anon;
grant execute on function public.tronco_da_sessao to authenticated;

-- 7) Tesoureiro: manda (agora ou no horário marcado) para os irmãos escolhidos; quem já recebeu nesta sessão não recebe de novo
create function public.tronco_enviar(p_sessao uuid, p_irmaos uuid[], p_quando timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  ts public.tronco_sessoes;
  pix jsonb;
  vals numeric[];
  v_quando timestamptz := case when p_quando is null or p_quando <= now() + interval '1 minute' then null else p_quando end;
  i record;
  cv public.tronco_convites;
  v_tel text;
  v_bot text[];
  v_not uuid;
  n_fila int := 0;
  n_sem int := 0;
  n_ja int := 0;
begin
  select * into s from public.sessoes where id = p_sessao;
  if s.id is null or not public.tem_permissao(s.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro envia o Tronco'; end if;
  if v_quando is not null and v_quando > now() + interval '7 days' then raise exception 'Agende para no máximo 7 dias'; end if;
  pix := private.tronco_pix_dados(s.loja_id);
  if pix->>'chave' is null then raise exception 'Cadastre a chave PIX em Tesouraria → Recebimento e PIX'; end if;
  vals := array(select jsonb_array_elements_text(pix->'valores')::numeric);

  insert into public.tronco_sessoes (loja_id, sessao_id, criado_por) values (s.loja_id, s.id, auth.uid())
  on conflict (sessao_id) do nothing;
  select * into ts from public.tronco_sessoes where sessao_id = s.id;
  if v_quando is not null then update public.tronco_sessoes set agendado_para = v_quando where id = ts.id; end if;

  for i in select ir.id, ir.nome, ir.telefone from public.irmaos ir
           where ir.loja_id = s.loja_id and ir.id = any (p_irmaos) and ir.situacao in ('ativo', 'licenciado') loop
    if exists (select 1 from public.tronco_convites where tronco_sessao_id = ts.id and irmao_id = i.id) then
      n_ja := n_ja + 1;
      continue;
    end if;
    insert into public.tronco_convites (loja_id, tronco_sessao_id, irmao_id) values (s.loja_id, ts.id, i.id) returning * into cv;
    v_tel := nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '');
    v_bot := array(select private.valor_curto(x) || '|tronco:' || x::text || ':' || cv.token from unnest(vals[1:2]) x)
             || ('Outro valor|tronco:outro:' || cv.token);
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status, botoes, enviar_apos)
    values (s.loja_id, i.id, 'tronco', cv.id,
      format('Olá, %s! Obrigado pela presença na sessão de %s. Se quiser contribuir com o Tronco de Beneficência, '
             'escolha o valor abaixo e receba o PIX. Vai inteiro para a beneficência, sem taxa, e ninguém na Loja vê '
             'quanto cada irmão deu.', private.primeiro_nome(i.nome), to_char(s.data, 'DD/MM')),
      v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end, v_bot, v_quando)
    returning id into v_not;
    update public.tronco_convites set notificacao_id = v_not where id = cv.id;
    if v_tel is null then n_sem := n_sem + 1; else n_fila := n_fila + 1; end if;
  end loop;
  return jsonb_build_object('na_fila', n_fila, 'sem_telefone', n_sem, 'ja_recebiam', n_ja, 'quando', v_quando);
end $$;
revoke execute on function public.tronco_enviar from public, anon;
grant execute on function public.tronco_enviar to authenticated;

-- 8) Tesoureiro: desmarca o envio agendado (o que ainda não saiu); dá para mandar de novo depois
create function public.tronco_cancelar_agendamento(p_sessao uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  ts public.tronco_sessoes;
  n int;
begin
  select * into ts from public.tronco_sessoes where sessao_id = p_sessao;
  if ts.id is null or not public.tem_permissao(ts.loja_id, 'tronco.editar') then raise exception 'Nada agendado'; end if;
  with c as (
    update public.notificacoes n set status = 'cancelado', erro = 'agendamento desfeito pelo Tesoureiro'
    from public.tronco_convites cv
    where cv.tronco_sessao_id = ts.id and n.id = cv.notificacao_id and n.status in ('pendente', 'sem_telefone')
      and n.enviar_apos > now()
    returning cv.id)
  delete from public.tronco_convites where id in (select id from c)
    and not exists (select 1 from public.tronco_contribuicoes t where t.tronco_sessao_id = ts.id
                    and t.irmao_id = tronco_convites.irmao_id);
  get diagnostics n = row_count;
  update public.tronco_sessoes set agendado_para = null where id = ts.id;
  return n;
end $$;
revoke execute on function public.tronco_cancelar_agendamento from public, anon;
grant execute on function public.tronco_cancelar_agendamento to authenticated;

-- 9) Tesoureiro: o dinheiro do saco entra na conta Tronco e no total da sessão
create function public.tronco_registrar_dinheiro(p_sessao uuid, p_valor numeric) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  ts public.tronco_sessoes;
  v_conta uuid;
  v_lanc uuid;
  v numeric(12,2) := round(p_valor, 2);
begin
  select * into s from public.sessoes where id = p_sessao;
  if s.id is null or not public.tem_permissao(s.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro lança o Tronco'; end if;
  if v is null or v <= 0 then raise exception 'Informe o valor em dinheiro'; end if;
  insert into public.tronco_sessoes (loja_id, sessao_id, criado_por) values (s.loja_id, s.id, auth.uid())
  on conflict (sessao_id) do nothing;
  select * into ts from public.tronco_sessoes where sessao_id = s.id for update;
  if ts.dinheiro_lancamento_id is not null
     and not exists (select 1 from public.lancamentos e where e.estorno_de = ts.dinheiro_lancamento_id) then
    raise exception 'O dinheiro desta sessão já foi lançado. Para corrigir, exclua o lançamento em Movimentações e lance de novo.';
  end if;
  select id into v_conta from public.contas_financeiras where loja_id = s.loja_id and tipo = 'tronco' and ativa limit 1;
  if v_conta is null then raise exception 'A Loja não tem conta Tronco ativa'; end if;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao)
  values (s.loja_id, v_conta, (select id from public.categorias_financeiras where loja_id = s.loja_id and codigo = 'tronco'),
          'receita', v, s.data, s.data, 'Tronco de Beneficência (dinheiro), sessão de ' || to_char(s.data, 'DD/MM/YYYY'))
  returning id into v_lanc;
  update public.tronco_sessoes set dinheiro = v, dinheiro_lancamento_id = v_lanc where id = ts.id;
  return v_lanc;
end $$;
revoke execute on function public.tronco_registrar_dinheiro from public, anon;
grant execute on function public.tronco_registrar_dinheiro to authenticated;

-- 10) WhatsApp (só a função do webhook): botão de valor, "Outro valor" ou "Já paguei"
create function public.whatsapp_tronco(p_loja uuid, p_telefone text, p_token text, p_opcao text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cv public.tronco_convites;
  c public.tronco_contribuicoes;
  pix jsonb;
  v_tel text;
begin
  cv := private.tronco_convite_valido(p_token);
  if cv.id is null or cv.loja_id <> p_loja then
    return jsonb_build_object('texto', 'Este convite para o Tronco já não vale. Contribua pelo sistema, em Tronco de Beneficência.');
  end if;
  select telefone into v_tel from public.irmaos where id = cv.irmao_id;
  if public.tel_chave(p_telefone) is distinct from public.tel_chave(v_tel) then return null; end if;
  if p_opcao = 'outro' then
    return jsonb_build_object('link', private.link_app('/tronco/' || cv.token));
  end if;
  if p_opcao = 'pago' then
    update public.tronco_contribuicoes set status = 'informada', informado_em = now()
    where id = (select id from public.tronco_contribuicoes where tronco_sessao_id = cv.tronco_sessao_id
                and irmao_id = cv.irmao_id and status = 'aguardando' order by informado_em desc limit 1);
    return jsonb_build_object('texto', 'Obrigado, irmão! A Tesouraria vai conferir no extrato.');
  end if;
  if p_opcao !~ '^[0-9]+(\.[0-9]{1,2})?$' then return null; end if;
  c := private.tronco_contribuir(cv, p_opcao::numeric);
  pix := private.tronco_pix_dados(p_loja);
  return pix - 'valores' || jsonb_build_object('valor', c.valor, 'token', cv.token);
end $$;
revoke execute on function public.whatsapp_tronco from public, anon, authenticated;
grant execute on function public.whatsapp_tronco to service_role;

-- 11) página do irmão sem login (/tronco/<token>)
create function public.tronco_convite_info(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  cv public.tronco_convites;
  pix jsonb;
begin
  cv := private.tronco_convite_valido(p_token);
  if cv.id is null then return jsonb_build_object('valido', false); end if;
  pix := private.tronco_pix_dados(cv.loja_id);
  return jsonb_build_object(
    'valido', true,
    'loja', (select nome || ' nº ' || numero from public.lojas where id = cv.loja_id),
    'primeiro_nome', (select private.primeiro_nome(nome) from public.irmaos where id = cv.irmao_id),
    'sessao', (select s.data from public.tronco_sessoes ts join public.sessoes s on s.id = ts.sessao_id where ts.id = cv.tronco_sessao_id),
    'valores', pix->'valores', 'tem_chave', pix->>'chave' is not null, 'automatico', pix->'automatico',
    'minhas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor, 'status', status) order by informado_em), '[]')
               from public.tronco_contribuicoes where tronco_sessao_id = cv.tronco_sessao_id and irmao_id = cv.irmao_id));
end $$;
revoke execute on function public.tronco_convite_info from public;
grant execute on function public.tronco_convite_info to anon, authenticated;

create function public.tronco_convite_valor(p_token text, p_valor numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cv public.tronco_convites;
  c public.tronco_contribuicoes;
begin
  cv := private.tronco_convite_valido(p_token);
  if cv.id is null then raise exception 'Este convite para o Tronco já não vale'; end if;
  c := private.tronco_contribuir(cv, p_valor);
  return private.tronco_pix_dados(cv.loja_id) - 'valores' || jsonb_build_object('id', c.id, 'valor', c.valor);
end $$;
revoke execute on function public.tronco_convite_valor from public;
grant execute on function public.tronco_convite_valor to anon, authenticated;

create function public.tronco_convite_ja_paguei(p_token text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare cv public.tronco_convites;
begin
  cv := private.tronco_convite_valido(p_token);
  if cv.id is null then raise exception 'Este convite para o Tronco já não vale'; end if;
  update public.tronco_contribuicoes set status = 'informada', informado_em = now()
  where id = p_id and status = 'aguardando' and tronco_sessao_id = cv.tronco_sessao_id and irmao_id = cv.irmao_id;
end $$;
revoke execute on function public.tronco_convite_ja_paguei from public;
grant execute on function public.tronco_convite_ja_paguei to anon, authenticated;

-- 12) ANONIMATO também no PIX do Tronco que cai na conta do Asaas (categoria Tronco, achado no teste desta
-- migration): o lançamento de receita do Tronco nunca guarda o irmão, em qualquer conta. Os antigos são limpos.
CREATE OR REPLACE FUNCTION private.tronco_sem_irmao()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.tipo = 'receita'
     and (exists (select 1 from public.contas_financeiras c where c.id = new.conta_id and c.tipo = 'tronco')
          or exists (select 1 from public.categorias_financeiras k where k.id = new.categoria_id and k.codigo = 'tronco')) then
    new.irmao_id := null;
  end if;
  return new;
end $function$;

select set_config('malhete.sistema', 'on', true);
update public.lancamentos l set irmao_id = null
from public.categorias_financeiras k
where k.id = l.categoria_id and k.codigo = 'tronco' and l.tipo = 'receita' and l.irmao_id is not null;
select set_config('malhete.sistema', 'off', true);
