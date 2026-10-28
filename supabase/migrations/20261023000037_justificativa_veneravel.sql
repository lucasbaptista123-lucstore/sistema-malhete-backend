-- Sistema Malhete — toda justificativa do irmão vai ao Venerável, que ACEITA ou NÃO ACEITA:
--   • antes da sessão: "não poderei ir" com motivo (confirmacoes)
--   • depois da sessão: justificativa da falta (presencas justificada_pelo_irmao)
-- O Venerável é avisado pelo WhatsApp (e no Início do sistema); o irmão recebe a decisão.
-- Não aceita = falta (presença 'ausente', mantém o texto). Aceita = falta justificada.

alter table public.presencas add column aceita boolean;
alter table public.confirmacoes
  add column ciente_em timestamptz,
  add column ciente_por uuid references auth.users(id),
  add column aceita boolean,
  add column parecer text;
alter table public.presencas add column parecer text;
create index on public.confirmacoes (ciente_por);
alter table public.avisos_config add column justificativas boolean not null default true;

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check
  check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema', 'justificativa'));

-- avisa o(s) Venerável(is) com cargo vigente pelo WhatsApp da loja
create function private.avisar_veneravel(p_loja uuid, p_sessao uuid, p_irmao uuid, p_texto text, p_antes boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
  v_nome text := (select nome from public.irmaos where id = p_irmao);
  v_data date := (select data from public.sessoes where id = p_sessao);
begin
  if not coalesce((select justificativas from public.avisos_config where loja_id = p_loja), true) then return; end if;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select p_loja, v.id, 'justificativa', p_sessao,
         format('Irmão %s, o irmão %s %s %s:%s“%s”%sPara aceitar ou não, abra: %s/app/chancelaria/justificativas',
                private.primeiro_nome(v.nome), v_nome,
                case when p_antes then 'avisou que não poderá comparecer à sessão de' else 'justificou a falta na sessão de' end,
                to_char(v_data, 'DD/MM'), E'\n', left(p_texto, 500), E'\n\n', v_url),
         nullif(regexp_replace(coalesce(v.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(v.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos v
  where v.loja_id = p_loja and v.id <> p_irmao and v.situacao = 'ativo'
    and exists (select 1 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
                where m.irmao_id = v.id and c.codigo = 'veneravel' and current_date between m.inicio and m.fim);
end $$;

create function public.avisar_justificativa_presenca() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.justificada_pelo_irmao and new.situacao = 'justificada' and new.ciente_em is null
     and (tg_op = 'INSERT' or new.justificativa is distinct from old.justificativa or old.situacao <> 'justificada') then
    perform private.avisar_veneravel(new.loja_id, new.sessao_id, new.irmao_id, new.justificativa, false);
  end if;
  return null;
end $$;
create trigger avisar_veneravel after insert or update of situacao, justificativa on public.presencas
for each row execute function public.avisar_justificativa_presenca();

create function public.avisar_justificativa_confirmacao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.resposta = 'nao_vou' and new.motivo is not null and new.ciente_em is null
     and (tg_op = 'INSERT' or old.motivo is null) then
    perform private.avisar_veneravel(new.loja_id, new.sessao_id, new.irmao_id, new.motivo, true);
  end if;
  return null;
end $$;
create trigger avisar_veneravel after insert or update of motivo on public.confirmacoes
for each row execute function public.avisar_justificativa_confirmacao();

-- Pendências do Venerável: as duas origens numa lista só
create function public.justificativas(p_loja uuid, p_todas boolean default false)
returns table (origem text, id uuid, sessao_id uuid, sessao_data date, irmao_id uuid, irmao text, texto text,
               via text, enviada_em timestamptz, ciente_em timestamptz, aceita boolean, parecer text)
language sql stable security definer set search_path = '' as $$
  select * from (
    select 'confirmacao'::text as origem, c.id, c.sessao_id, s.data as sessao_data, c.irmao_id, i.nome as irmao,
           c.motivo as texto, c.canal as via, c.respondido_em as enviada_em, c.ciente_em, c.aceita, c.parecer
    from public.confirmacoes c join public.sessoes s on s.id = c.sessao_id join public.irmaos i on i.id = c.irmao_id
    where c.loja_id = p_loja and c.resposta = 'nao_vou' and c.motivo is not null
    union all
    select 'presenca', p.id, p.sessao_id, s.data, p.irmao_id, i.nome, p.justificativa, p.justificada_via, p.registrado_em,
           p.ciente_em, p.aceita, p.parecer
    from public.presencas p join public.sessoes s on s.id = p.sessao_id join public.irmaos i on i.id = p.irmao_id
    where p.loja_id = p_loja and p.justificada_pelo_irmao and p.justificativa is not null
  ) x
  where (public.tem_permissao(p_loja, 'loja.config') or public.tem_permissao(p_loja, 'chancelaria.ler'))
    and (p_todas or x.ciente_em is null)
  order by x.enviada_em desc
  limit 300
$$;

-- Venerável aceita (vira falta justificada) ou não aceita (vira falta), com observação opcional; o irmão é avisado.
create function public.avaliar_justificativa(p_origem text, p_id uuid, p_aceita boolean, p_parecer text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_loja uuid; v_sessao uuid; v_irmao uuid; v_data date; v_tel text; v_nome text;
begin
  if p_origem = 'confirmacao' then
    select loja_id, sessao_id, irmao_id into v_loja, v_sessao, v_irmao from public.confirmacoes where id = p_id;
  elsif p_origem = 'presenca' then
    select loja_id, sessao_id, irmao_id into v_loja, v_sessao, v_irmao from public.presencas where id = p_id;
  end if;
  if v_loja is null or not public.tem_permissao(v_loja, 'loja.config') then raise exception 'Só o Venerável Mestre aceita justificativas'; end if;
  if p_aceita is null then raise exception 'Escolha aceitar ou não aceitar'; end if;

  if p_origem = 'confirmacao' then
    update public.confirmacoes set ciente_em = now(), ciente_por = auth.uid(), aceita = p_aceita, parecer = nullif(trim(p_parecer), '')
    where id = p_id;
  end if;
  -- reflete na presença (se o Chanceler já marcou, ou se a justificativa veio depois da sessão); "presente" não muda
  update public.presencas
  set situacao = case when p_aceita then 'justificada' else 'ausente' end,
      justificativa = coalesce(justificativa, (select motivo from public.confirmacoes where id = p_id)),
      ciente_em = now(), ciente_por = auth.uid(), aceita = p_aceita, parecer = nullif(trim(p_parecer), '')
  where sessao_id = v_sessao and irmao_id = v_irmao and situacao <> 'presente';

  -- devolve a decisão ao irmão
  select data into v_data from public.sessoes where id = v_sessao;
  select nome, nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_nome, v_tel from public.irmaos where id = v_irmao;
  if coalesce((select justificativas from public.avisos_config where loja_id = v_loja), true) then
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (v_loja, v_irmao, 'justificativa', v_sessao,
            format('Irmão %s, o Venerável Mestre %s sua justificativa da sessão de %s.%s',
                   private.primeiro_nome(v_nome), case when p_aceita then 'aceitou' else 'não aceitou' end, to_char(v_data, 'DD/MM'),
                   coalesce(E'\n' || nullif(trim(p_parecer), ''), '')),
            v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
  end if;
end $$;

-- o Chanceler, ao preencher a presença pelas respostas, já respeita uma decisão anterior do Venerável
create or replace function public.validar_presenca() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  c public.confirmacoes;
begin
  select * into s from public.sessoes where id = new.sessao_id;
  if s.loja_id <> new.loja_id or not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Sessão ou irmão de outra loja';
  end if;
  if s.status = 'cancelada' then
    raise exception 'Sessão cancelada';
  end if;
  if new.situacao <> 'justificada' and (select grau from public.irmaos where id = new.irmao_id) < s.grau then
    raise exception 'O grau do irmão é menor que o grau da sessão';
  end if;
  if tg_op = 'INSERT' and new.situacao = 'justificada' then
    select * into c from public.confirmacoes where sessao_id = new.sessao_id and irmao_id = new.irmao_id;
    if c.aceita is not null then
      new.situacao := case when c.aceita then 'justificada' else 'ausente' end;
      new.ciente_em := c.ciente_em; new.ciente_por := c.ciente_por; new.aceita := c.aceita; new.parecer := c.parecer;
    end if;
  end if;
  new.registrado_por := auth.uid();
  new.registrado_em := now();
  return new;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.avisar_justificativa_presenca, public.avisar_justificativa_confirmacao from public, anon, authenticated;
revoke execute on function public.justificativas, public.avaliar_justificativa from public, anon;
grant execute on function public.justificativas, public.avaliar_justificativa to authenticated;
