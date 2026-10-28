-- Sistema Malhete — ADMISSÃO (iniciação e filiação) com trâmite eletrônico.
-- Etapas: ficha (candidato preenche por link, com documentos) → sindicância (sindicantes designados pelo
-- Venerável; pareceres sigilosos: só o próprio sindicante e o Venerável leem) → placet (aguardando o placet
-- do GOB) → cerimônia (placet anexado como documento) → concluído (o candidato vira irmão do quadro).
-- Escrutínio NÃO entra: é feito em Loja (o GOB não permite virtual) — o Venerável só avança a etapa.
-- Quem vê o processo: Venerável (loja.config), Secretaria (secretaria.ler), o proponente e os sindicantes.

create table public.processos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tipo text not null check (tipo in ('iniciacao', 'filiacao')),
  nome text not null check (length(trim(nome)) > 0),
  email text,
  telefone text,
  proponente_id uuid references public.irmaos(id),
  etapa text not null default 'ficha' check (etapa in ('ficha', 'sindicancia', 'placet', 'cerimonia', 'concluido', 'arquivado')),
  dados jsonb not null default '{}'::jsonb,          -- a ficha (campos livres, definidos no app)
  token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  ficha_enviada_em timestamptz,
  placet_numero text,
  placet_data date,
  data_cerimonia date,
  irmao_id uuid references public.irmaos(id),         -- o irmão criado ao concluir
  motivo_arquivo text,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.processos (loja_id, etapa);
create index on public.processos (proponente_id);
create index on public.processos (irmao_id);
create index on public.processos (criado_por);

create table public.sindicancias (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  processo_id uuid not null references public.processos(id) on delete cascade,
  sindicante_id uuid not null references public.irmaos(id),
  parecer text check (parecer in ('favoravel', 'desfavoravel')),
  relatorio text,
  arquivo_caminho text,
  arquivo_nome text,
  enviado_em timestamptz,
  designado_em timestamptz not null default now(),
  unique (processo_id, sindicante_id)
);
create index on public.sindicancias (sindicante_id);
create index on public.sindicancias (loja_id);

create table public.processo_documentos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  processo_id uuid not null references public.processos(id) on delete cascade,
  tipo text not null,                                  -- foto, rg, cpf, residencia, antecedentes, placet, outro…
  arquivo_caminho text not null,
  arquivo_nome text not null,
  pelo_candidato boolean not null default false,
  enviado_por uuid default auth.uid() references auth.users(id),
  enviado_em timestamptz not null default now()
);
create index on public.processo_documentos (processo_id);
create index on public.processo_documentos (loja_id);
create index on public.processo_documentos (enviado_por);

create table public.processo_eventos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  processo_id uuid not null references public.processos(id) on delete cascade,
  descricao text not null,
  por uuid default auth.uid() references auth.users(id),
  em timestamptz not null default now()
);
create index on public.processo_eventos (processo_id);
create index on public.processo_eventos (loja_id);
create index on public.processo_eventos (por);

-- quem gerencia (Venerável/Secretaria) e quem participa (proponente, sindicantes)
create function public.gere_processos(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.tem_permissao(p_loja, 'loja.config') or public.tem_permissao(p_loja, 'secretaria.editar')
$$;
create function public.pode_ver_processo(p_processo uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.processos p
    where p.id = p_processo
      and (public.tem_permissao(p.loja_id, 'loja.config') or public.tem_permissao(p.loja_id, 'secretaria.ler')
           or p.proponente_id = public.meu_irmao_id(p.loja_id)
           or exists (select 1 from public.sindicancias s where s.processo_id = p.id and s.sindicante_id = public.meu_irmao_id(p.loja_id))))
$$;

alter table public.processos enable row level security;
alter table public.sindicancias enable row level security;
alter table public.processo_documentos enable row level security;
alter table public.processo_eventos enable row level security;
create policy le on public.processos for select to authenticated using ((select public.pode_ver_processo(id)));
-- sigilo: o parecer só é lido pelo próprio sindicante e pelo Venerável (os demais veem o andamento por processo_sindicantes)
create policy le on public.sindicancias for select to authenticated
  using (sindicante_id = (select public.meu_irmao_id(loja_id)) or (select public.tem_permissao(loja_id, 'loja.config')));
create policy le on public.processo_documentos for select to authenticated using ((select public.pode_ver_processo(processo_id)));
create policy le on public.processo_eventos for select to authenticated using ((select public.pode_ver_processo(processo_id)));
create trigger auditoria after insert or update or delete on public.processos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.sindicancias for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.processo_documentos for each row execute function public.registrar_auditoria();

create function private.evento_processo(p public.processos, p_txt text) returns void
language sql security definer set search_path = '' as $$
  insert into public.processo_eventos (loja_id, processo_id, descricao) values (p.loja_id, p.id, p_txt)
$$;

-- abrir: Venerável, Secretaria ou um Mestre ativo (que fica como proponente)
create function public.abrir_processo(p_loja uuid, p_tipo text, p_nome text, p_email text default null, p_telefone text default null,
                                      p_proponente uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_eu uuid := public.meu_irmao_id(p_loja);
  v_prop uuid := p_proponente;
  v_id uuid;
begin
  if not public.gere_processos(p_loja) then
    if v_eu is null or not exists (select 1 from public.irmaos where id = v_eu and grau = 3 and situacao = 'ativo') then
      raise exception 'Só Mestres, a Secretaria ou o Venerável propõem candidatos';
    end if;
    v_prop := v_eu;
  end if;
  if v_prop is not null and not exists (select 1 from public.irmaos where id = v_prop and loja_id = p_loja and grau = 3) then
    raise exception 'O proponente precisa ser Mestre desta Loja';
  end if;
  insert into public.processos (loja_id, tipo, nome, email, telefone, proponente_id)
  values (p_loja, p_tipo, trim(p_nome), nullif(trim(p_email), ''), nullif(trim(p_telefone), ''), v_prop)
  returning id into v_id;
  insert into public.processo_eventos (loja_id, processo_id, descricao)
  values (p_loja, v_id, case p_tipo when 'iniciacao' then 'Proposta de iniciação aberta' else 'Pedido de filiação aberto' end);
  return v_id;
end $$;

-- a ficha também pode ser preenchida/corrigida por quem gere (ex.: candidato entregou em papel)
create function public.salvar_ficha_processo(p_processo uuid, p_dados jsonb, p_nome text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.gere_processos(p.loja_id) then raise exception 'Sem permissão'; end if;
  if p.etapa in ('concluido', 'arquivado') then raise exception 'Processo encerrado'; end if;
  update public.processos set dados = coalesce(p_dados, '{}'::jsonb), nome = coalesce(nullif(trim(p_nome), ''), nome) where id = p.id;
end $$;

-- ======================= candidato (sem login, pelo link) =======================
create function public.ficha_candidato(p_token text)
returns table (tipo text, nome text, loja text, dados jsonb, enviada boolean, aberta boolean, processo uuid, loja_id uuid,
               documentos jsonb)
language sql stable security definer set search_path = '' as $$
  select p.tipo, p.nome, trim(l.nome) || coalesce(' nº ' || l.numero, ''), p.dados, p.ficha_enviada_em is not null,
         p.etapa = 'ficha' and p.ficha_enviada_em is null, p.id, p.loja_id,
         coalesce((select jsonb_agg(jsonb_build_object('tipo', d.tipo, 'nome', d.arquivo_nome) order by d.enviado_em)
                   from public.processo_documentos d where d.processo_id = p.id and d.pelo_candidato), '[]'::jsonb)
  from public.processos p join public.lojas l on l.id = p.loja_id
  where p.token = p_token and length(p_token) >= 32
$$;

create function public.salvar_ficha_candidato(p_token text, p_dados jsonb, p_enviar boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where token = p_token and length(p_token) >= 32 for update;
  if p.id is null then raise exception 'Link inválido'; end if;
  if p.etapa <> 'ficha' or p.ficha_enviada_em is not null then raise exception 'Esta ficha já foi enviada. Fale com quem o indicou.'; end if;
  if pg_column_size(p_dados) > 60000 then raise exception 'Ficha grande demais'; end if;
  update public.processos set dados = coalesce(p_dados, '{}'::jsonb),
         ficha_enviada_em = case when p_enviar then now() end
  where id = p.id;
  if p_enviar then perform private.evento_processo(p, 'Ficha enviada pelo candidato'); end if;
end $$;

-- caminho do candidato: <loja>/<processo>/candidato/<token>/<arquivo>
create function public.candidato_pode_enviar(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_proc uuid;
begin
  begin v_proc := split_part(p_nome, '/', 2)::uuid; exception when others then return false; end;
  return split_part(p_nome, '/', 3) = 'candidato' and exists (
    select 1 from public.processos p
    where p.id = v_proc and p.loja_id = public.loja_do_caminho(p_nome) and p.token = split_part(p_nome, '/', 4)
      and p.etapa = 'ficha' and p.ficha_enviada_em is null);
end $$;

create function public.anexar_documento_candidato(p_token text, p_tipo text, p_caminho text, p_nome text) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where token = p_token and length(p_token) >= 32;
  if p.id is null or not public.candidato_pode_enviar(p_caminho) or split_part(p_caminho, '/', 4) <> p_token then
    raise exception 'Envio não permitido';
  end if;
  if (select count(*) from public.processo_documentos where processo_id = p.id and pelo_candidato) >= 30 then
    raise exception 'Limite de documentos atingido';
  end if;
  insert into public.processo_documentos (loja_id, processo_id, tipo, arquivo_caminho, arquivo_nome, pelo_candidato, enviado_por)
  values (p.loja_id, p.id, left(p_tipo, 40), p_caminho, left(p_nome, 200), true, null);
end $$;

-- quem gere anexa documentos (inclusive o placet) pelo sistema
create function public.anexar_documento_processo(p_processo uuid, p_tipo text, p_caminho text, p_nome text) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where id = p_processo;
  if p.id is null or not public.gere_processos(p.loja_id) then raise exception 'Sem permissão'; end if;
  if split_part(p_caminho, '/', 2) <> p.id::text or public.loja_do_caminho(p_caminho) <> p.loja_id then raise exception 'Caminho inválido'; end if;
  insert into public.processo_documentos (loja_id, processo_id, tipo, arquivo_caminho, arquivo_nome)
  values (p.loja_id, p.id, left(p_tipo, 40), p_caminho, left(p_nome, 200));
end $$;

-- ======================= sindicância =======================
create function public.designar_sindicantes(p_processo uuid, p_irmaos uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p public.processos;
  v uuid;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Só o Venerável designa sindicantes'; end if;
  if p.etapa not in ('ficha', 'sindicancia') then raise exception 'A sindicância já foi encerrada'; end if;
  if coalesce(array_length(p_irmaos, 1), 0) = 0 then raise exception 'Escolha ao menos um sindicante'; end if;
  foreach v in array p_irmaos loop
    if not exists (select 1 from public.irmaos where id = v and loja_id = p.loja_id and grau = 3 and situacao = 'ativo') then
      raise exception 'Sindicante precisa ser Mestre ativo da Loja';
    end if;
    if v = p.proponente_id then raise exception 'O proponente não pode ser sindicante'; end if;
  end loop;
  -- tira quem saiu da lista e ainda não deu parecer
  delete from public.sindicancias where processo_id = p.id and enviado_em is null and not (sindicante_id = any (p_irmaos));
  insert into public.sindicancias (loja_id, processo_id, sindicante_id)
  select p.loja_id, p.id, x from unnest(p_irmaos) x on conflict do nothing;
  update public.processos set etapa = 'sindicancia', ficha_enviada_em = coalesce(ficha_enviada_em, now()) where id = p.id;
  perform private.evento_processo(p, format('Sindicantes designados (%s)', array_length(p_irmaos, 1)));
end $$;

create function public.enviar_parecer(p_sindicancia uuid, p_parecer text, p_relatorio text,
                                      p_arquivo_caminho text default null, p_arquivo_nome text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.sindicancias;
  p public.processos;
begin
  select * into s from public.sindicancias where id = p_sindicancia for update;
  if s.id is null or s.sindicante_id is distinct from public.meu_irmao_id(s.loja_id) then raise exception 'Este parecer não é seu'; end if;
  select * into p from public.processos where id = s.processo_id;
  if p.etapa <> 'sindicancia' then raise exception 'A sindicância deste processo já foi encerrada'; end if;
  if p_parecer not in ('favoravel', 'desfavoravel') then raise exception 'Escolha favorável ou desfavorável'; end if;
  if length(trim(coalesce(p_relatorio, ''))) < 10 then raise exception 'Escreva o relatório da sindicância'; end if;
  if p_arquivo_caminho is not null and split_part(p_arquivo_caminho, '/', 4) <> s.id::text then raise exception 'Arquivo inválido'; end if;
  update public.sindicancias set parecer = p_parecer, relatorio = trim(p_relatorio),
         arquivo_caminho = coalesce(p_arquivo_caminho, arquivo_caminho), arquivo_nome = coalesce(p_arquivo_nome, arquivo_nome),
         enviado_em = now()
  where id = s.id;
  perform private.evento_processo(p, 'Parecer de sindicância entregue');
end $$;

-- andamento sem expor o conteúdo (para Secretaria/proponente): quem foi designado e se já entregou
create function public.processo_sindicantes(p_processo uuid)
returns table (id uuid, sindicante_id uuid, nome text, entregue boolean, enviado_em timestamptz, parecer text, eu boolean)
language sql stable security definer set search_path = '' as $$
  select s.id, s.sindicante_id, i.nome, s.enviado_em is not null, s.enviado_em,
         case when public.tem_permissao(s.loja_id, 'loja.config') or s.sindicante_id = public.meu_irmao_id(s.loja_id) then s.parecer end,
         s.sindicante_id = public.meu_irmao_id(s.loja_id)
  from public.sindicancias s join public.irmaos i on i.id = s.sindicante_id
  where s.processo_id = p_processo and public.pode_ver_processo(p_processo)
  order by i.nome
$$;

-- Venerável encerra a sindicância: segue para o placet do GOB (o escrutínio é feito em Loja) ou arquiva
create function public.encerrar_sindicancia(p_processo uuid, p_seguir boolean, p_obs text default null) returns void
language plpgsql security definer set search_path = '' as $$
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
    perform private.evento_processo(p, 'Sindicância encerrada — aguardando o placet do GOB' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
  else
    update public.processos set etapa = 'arquivado', motivo_arquivo = coalesce(nullif(trim(p_obs), ''), 'Não aprovado') where id = p.id;
    perform private.evento_processo(p, 'Processo arquivado' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
  end if;
end $$;

-- placet do GOB recebido (o arquivo vai por anexar_documento_processo com tipo 'placet')
create function public.registrar_placet(p_processo uuid, p_numero text, p_data date, p_cerimonia date default null) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Só o Venerável registra o placet'; end if;
  if p.etapa not in ('placet', 'cerimonia') then raise exception 'O processo não está aguardando placet'; end if;
  if nullif(trim(coalesce(p_numero, '')), '') is null or p_data is null then raise exception 'Informe número e data do placet'; end if;
  update public.processos set etapa = 'cerimonia', placet_numero = trim(p_numero), placet_data = p_data,
         data_cerimonia = coalesce(p_cerimonia, data_cerimonia)
  where id = p.id;
  perform private.evento_processo(p, format('Placet nº %s de %s registrado', trim(p_numero), to_char(p_data, 'DD/MM/YYYY')));
end $$;

-- conclui: cria o irmão no quadro com os dados da ficha (iniciação = Aprendiz, CIM pode vir depois do GOB)
create function public.concluir_processo(p_processo uuid, p_data date, p_cim text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
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
                                     || ' — incluído no quadro de obreiros');
  return v_irmao;
end $$;

create function public.arquivar_processo(p_processo uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.processos;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Só o Venerável arquiva'; end if;
  if p.etapa in ('concluido', 'arquivado') then raise exception 'Processo já encerrado'; end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then raise exception 'Informe o motivo'; end if;
  update public.processos set etapa = 'arquivado', motivo_arquivo = trim(p_motivo) where id = p.id;
  perform private.evento_processo(p, 'Processo arquivado: ' || trim(p_motivo));
end $$;

-- novo link para o candidato (reabre a ficha para correção)
create function public.reabrir_ficha(p_processo uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare p public.processos; v text;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not public.gere_processos(p.loja_id) then raise exception 'Sem permissão'; end if;
  if p.etapa <> 'ficha' then raise exception 'A ficha só pode ser reaberta antes da sindicância'; end if;
  update public.processos set ficha_enviada_em = null where id = p.id returning token into v;
  perform private.evento_processo(p, 'Ficha reaberta para correção do candidato');
  return v;
end $$;

-- ======================= arquivos =======================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('processos', 'processos', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp',
              'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

-- <loja>/<processo>/sindicancia/<sindicancia>/<arquivo> → só o sindicante e o Venerável; o resto → quem vê o processo
create function public.pode_ler_arquivo_processo(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_proc uuid; v_sind uuid;
begin
  begin v_proc := split_part(p_nome, '/', 2)::uuid; exception when others then return false; end;
  if split_part(p_nome, '/', 3) = 'sindicancia' then
    begin v_sind := split_part(p_nome, '/', 4)::uuid; exception when others then return false; end;
    return exists (select 1 from public.sindicancias s where s.id = v_sind and s.processo_id = v_proc
                   and (s.sindicante_id = public.meu_irmao_id(s.loja_id) or public.tem_permissao(s.loja_id, 'loja.config')));
  end if;
  return public.pode_ver_processo(v_proc);
end $$;
create function public.pode_enviar_arquivo_processo(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_proc uuid; v_sind uuid; v_loja uuid := public.loja_do_caminho(p_nome);
begin
  begin v_proc := split_part(p_nome, '/', 2)::uuid; exception when others then return false; end;
  if not exists (select 1 from public.processos where id = v_proc and loja_id = v_loja) then return false; end if;
  if split_part(p_nome, '/', 3) = 'sindicancia' then
    begin v_sind := split_part(p_nome, '/', 4)::uuid; exception when others then return false; end;
    return exists (select 1 from public.sindicancias s where s.id = v_sind and s.processo_id = v_proc
                   and s.sindicante_id = public.meu_irmao_id(s.loja_id));
  end if;
  return split_part(p_nome, '/', 3) = 'docs' and public.gere_processos(v_loja);
end $$;

create policy processos_le on storage.objects for select to authenticated
  using (bucket_id = 'processos' and public.pode_ler_arquivo_processo(name));
create policy processos_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'processos' and public.pode_enviar_arquivo_processo(name));
create policy processos_candidato on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'processos' and public.candidato_pode_enviar(name));

revoke execute on function public.gere_processos, public.pode_ver_processo, public.abrir_processo, public.salvar_ficha_processo,
  public.anexar_documento_processo, public.designar_sindicantes, public.enviar_parecer, public.processo_sindicantes,
  public.encerrar_sindicancia, public.registrar_placet, public.concluir_processo, public.arquivar_processo, public.reabrir_ficha,
  public.pode_ler_arquivo_processo, public.pode_enviar_arquivo_processo from public, anon;
grant execute on function public.gere_processos, public.pode_ver_processo, public.abrir_processo, public.salvar_ficha_processo,
  public.anexar_documento_processo, public.designar_sindicantes, public.enviar_parecer, public.processo_sindicantes,
  public.encerrar_sindicancia, public.registrar_placet, public.concluir_processo, public.arquivar_processo, public.reabrir_ficha,
  public.pode_ler_arquivo_processo, public.pode_enviar_arquivo_processo to authenticated;
revoke execute on function public.ficha_candidato, public.salvar_ficha_candidato, public.candidato_pode_enviar,
  public.anexar_documento_candidato from public;
grant execute on function public.ficha_candidato, public.salvar_ficha_candidato, public.candidato_pode_enviar,
  public.anexar_documento_candidato to anon, authenticated;
revoke execute on function private.evento_processo from public, anon, authenticated;
