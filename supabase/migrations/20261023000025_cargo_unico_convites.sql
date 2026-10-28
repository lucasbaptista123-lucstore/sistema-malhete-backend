-- Sistema Malhete — (1) um irmão não ocupa dois cargos no mesmo período, nem dois irmãos o mesmo cargo;
-- (2) primeiro acesso por convite: o Secretário gera um link (enviado pelo WhatsApp da loja ou copiado),
-- o irmão cria a conta por ele e já entra vinculado ao próprio cadastro.

-- =========================================================
-- Um cargo por irmão (vale daqui para a frente; dados antigos ficam como estão)
-- =========================================================

create function public.validar_mandato() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_cargo text;
  v_irmao text;
begin
  select c.nome into v_cargo
  from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
  where m.irmao_id = new.irmao_id and m.id <> new.id
    and daterange(m.inicio, m.fim, '[]') && daterange(new.inicio, new.fim, '[]')
  limit 1;
  if v_cargo is not null then
    raise exception 'Este irmão já ocupa o cargo de % nesse período. Um irmão não pode ter dois cargos.', v_cargo;
  end if;
  select i.nome into v_irmao
  from public.mandatos m join public.irmaos i on i.id = m.irmao_id
  where m.cargo_id = new.cargo_id and m.id <> new.id
    and daterange(m.inicio, m.fim, '[]') && daterange(new.inicio, new.fim, '[]')
  limit 1;
  if v_irmao is not null then
    raise exception 'Esse cargo já está com o irmão % nesse período.', v_irmao;
  end if;
  return new;
end $$;
create trigger validar before insert or update of irmao_id, cargo_id, inicio, fim on public.mandatos
for each row execute function public.validar_mandato();

-- =========================================================
-- Convites de primeiro acesso
-- =========================================================

create table public.convites (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  expira_em timestamptz not null default now() + interval '14 days',
  usado_em timestamptz,
  usado_por uuid references auth.users(id),
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.convites (irmao_id);
create index on public.convites (loja_id);
create index on public.convites (usado_por);
create index on public.convites (criado_por);
alter table public.convites enable row level security;
create policy le on public.convites for select to authenticated
  using ((select public.tem_permissao(loja_id, 'cadastro.editar')));
create trigger auditoria after insert or update or delete on public.convites for each row execute function public.registrar_auditoria();

-- Secretário (cadastro.editar) gera o convite; com WhatsApp conectado e telefone, já vai para a fila.
create function public.convidar_irmao(p_irmao uuid, p_enviar_whatsapp boolean default true)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  i public.irmaos;
  v_token text;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
  v_loja text;
  v_tel text;
begin
  select * into i from public.irmaos where id = p_irmao;
  if i.id is null or not public.tem_permissao(i.loja_id, 'cadastro.editar') then raise exception 'Sem permissão'; end if;
  if i.user_id is not null then raise exception 'Este irmão já tem acesso ao sistema'; end if;
  if i.situacao not in ('ativo', 'licenciado') then raise exception 'Só irmãos ativos ou licenciados recebem convite'; end if;

  update public.convites set expira_em = now() where irmao_id = p_irmao and usado_em is null and expira_em > now();
  insert into public.convites (loja_id, irmao_id) values (i.loja_id, p_irmao) returning token into v_token;

  v_tel := nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '');
  if p_enviar_whatsapp and v_tel is not null then
    select trim(nome) into v_loja from public.lojas where id = i.loja_id;
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (i.loja_id, p_irmao, 'convite', null,
            format('Olá, %s! Você foi convidado a usar o sistema da %s. Crie seu acesso por este link (vale por 14 dias):%s%s/convite/%s',
                   private.primeiro_nome(i.nome), v_loja, E'\n', v_url, v_token),
            v_tel, 'pendente');
  end if;
  return v_url || '/convite/' || v_token;
end $$;

-- Página pública do convite (sem login): só o primeiro nome, o e-mail cadastrado e a loja.
create function public.convite_info(p_token text)
returns table (valido boolean, primeiro_nome text, email text, loja text)
language sql stable security definer set search_path = '' as $$
  select c.usado_em is null and c.expira_em > now() and i.user_id is null,
         private.primeiro_nome(i.nome), i.email, trim(l.nome)
  from public.convites c join public.irmaos i on i.id = c.irmao_id join public.lojas l on l.id = c.loja_id
  where c.token = p_token
$$;

-- Depois do login (conta nova ou já existente): vincula o usuário ao cadastro do irmão.
create function public.aceitar_convite(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  c public.convites;
begin
  if auth.uid() is null then raise exception 'Faça login'; end if;
  select * into c from public.convites where token = p_token for update;
  if c.id is null or c.usado_em is not null or c.expira_em < now() then raise exception 'Convite inválido ou vencido. Peça um novo ao Secretário.'; end if;
  if exists (select 1 from public.irmaos where loja_id = c.loja_id and user_id = auth.uid()) then
    raise exception 'Sua conta já está ligada a um irmão desta loja';
  end if;
  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos set user_id = auth.uid() where id = c.irmao_id and user_id is null;
  if not found then raise exception 'Este cadastro já tem acesso'; end if;
  perform set_config('malhete.sistema', 'off', true);
  update public.convites set usado_em = now(), usado_por = auth.uid() where id = c.id;
  return c.loja_id;
end $$;

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check
  check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite'));

revoke execute on function public.validar_mandato from public, anon, authenticated;
revoke execute on function public.convidar_irmao, public.aceitar_convite from public, anon;
grant execute on function public.convidar_irmao, public.aceitar_convite to authenticated;
revoke execute on function public.convite_info from public;
grant execute on function public.convite_info to anon, authenticated;
