-- Administrador da implantação: quem cadastra a Loja administra tudo (menos a Tesouraria de quem tem o cargo)
-- até o Venerável Mestre da gestão em vigor entrar no sistema. Daí em diante fica só com o do próprio cargo.
-- O Venerável (pelo cargo) pode dar ou tirar o acesso de administrador; o que ele dá não expira.
-- Cargo já exercido não se reescreve: só se substitui, com data e motivo.

alter table public.irmaos add column admin_implantacao boolean not null default false;
update public.irmaos set admin_implantacao = true where admin_loja;

alter table public.mandatos add column criado_em timestamptz not null default now();

-- Venerável Mestre da gestão em vigor, já com acesso ao sistema
create function private.tem_veneravel(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mandatos m
    join public.loja_cargos c on c.id = m.cargo_id and c.codigo = 'veneravel'
    join public.irmaos v on v.id = m.irmao_id
    where m.loja_id = p_loja and current_date between m.inicio and m.fim
      and v.user_id is not null and v.situacao = 'ativo')
$$;

create function private.admin_ativo(p_loja uuid, p_admin boolean, p_implantacao boolean) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_admin and (not p_implantacao or not private.tem_veneravel(p_loja))
$$;

-- quem chama é o Venerável pelo cargo (não basta ser administrador)
create function private.e_veneravel(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.irmaos i
    join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
    join public.loja_cargos c on c.id = m.cargo_id and c.codigo = 'veneravel'
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo' and private.mfa_ok())
$$;

create or replace function private.tem_permissao_base(p_loja uuid, p_perm text)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  with exclusiva as (
    select p_perm = any (public.permissoes_exclusivas()) as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo' and private.mfa_ok()
      and (
        (private.admin_ativo(p_loja, i.admin_loja, i.admin_implantacao) and (
           not x.sim
           or not exists (
             select 1 from public.mandatos m2
             join public.loja_cargos c2 on c2.id = m2.cargo_id
             where m2.loja_id = p_loja and current_date between m2.inicio and m2.fim
               and p_perm = any (c2.permissoes))))
        or exists (
          select 1 from public.mandatos m
          join public.loja_cargos c on c.id = m.cargo_id
          where m.irmao_id = i.id
            and current_date between m.inicio and m.fim
            and (
              ('*' = any (c.permissoes) and not x.sim)
              or p_perm = any (c.permissoes)
              or (p_perm like '%.ler' and replace(p_perm, '.ler', '.editar') = any (c.permissoes))
            )
        )
      )
  )
$function$;

create or replace function public.minhas_permissoes(p_loja uuid)
 returns text[]
 language sql
 stable security definer
 set search_path to ''
as $function$
  with base as (
    select case
      when bool_or(private.admin_ativo(p_loja, i.admin_loja, i.admin_implantacao)) then array['*']
      else coalesce(array_agg(distinct p) filter (where p is not null), '{}')
    end as perms
    from public.irmaos i
    left join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
    left join public.loja_cargos c on c.id = m.cargo_id
    left join lateral unnest(c.permissoes) as p on true
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
  )
  select array(
    select distinct x from (
      select unnest(b.perms) as x from base b
      union all
      select e from unnest(public.permissoes_exclusivas()) e where public.tem_permissao(p_loja, e)
    ) t
    where x <> '' and (x <> all (public.permissoes_exclusivas()) or public.tem_permissao(p_loja, x))
  )
$function$;

create or replace function public.pode_avaliar(p_loja uuid, p_grau smallint)
 returns boolean
 language sql
 stable security definer
 set search_path to ''
as $function$
  select exists (
    select 1 from public.irmaos i
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
      and (private.admin_ativo(p_loja, i.admin_loja, i.admin_implantacao) or exists (
        select 1 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
        where m.irmao_id = i.id and current_date between m.inicio and m.fim
          and ('*' = any (c.permissoes)
               or ('trabalhos.avaliar' = any (c.permissoes) and c.grau_acompanhado = p_grau)))))
$function$;

create or replace function public.criar_loja(p_nome text, p_numero text, p_oriente_id uuid, p_rito_id uuid, p_cidade text, p_uf character, p_meu_nome text, p_meu_grau smallint default 3)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_loja uuid;
begin
  if auth.uid() is null then
    raise exception 'Faça login para cadastrar a loja';
  end if;
  if not exists (select 1 from public.ritos where id = p_rito_id and ativo) then
    raise exception 'Rito ainda não disponível';
  end if;

  insert into public.lojas (oriente_id, rito_id, nome, numero, cidade, uf, criado_por)
  values (p_oriente_id, p_rito_id, p_nome, p_numero, p_cidade, p_uf, auth.uid())
  returning id into v_loja;

  insert into public.loja_cargos (loja_id, rito_cargo_id, codigo, nome, ordem, grau_acompanhado, permissoes)
  select v_loja, id, codigo, nome, ordem, grau_acompanhado, permissoes
  from public.rito_cargos where rito_id = p_rito_id;

  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, user_id, admin_loja, admin_implantacao, nome, email, grau)
  values (v_loja, auth.uid(), true, true, p_meu_nome,
          (select email from auth.users where id = auth.uid()), p_meu_grau);

  perform set_config('malhete.sistema', 'off', true);
  insert into public.assinaturas (loja_id) values (v_loja);

  return v_loja;
end $function$;

create or replace function public.proteger_campos_irmao()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  new.atualizado_em := now();
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return new;
  end if;
  if (new.grau is distinct from old.grau or new.mestre_instalado is distinct from old.mestre_instalado)
     and not public.tem_permissao(old.loja_id, 'graus.editar') then
    raise exception 'Só o Venerável Mestre ou o Secretário alteram o grau do irmão';
  end if;
  if new.admin_loja is distinct from old.admin_loja then
    if not private.e_veneravel(old.loja_id) then
      raise exception 'Só o Venerável Mestre define o administrador da loja';
    end if;
    new.admin_implantacao := false;  -- dado pelo Venerável não expira
  else
    new.admin_implantacao := old.admin_implantacao;
  end if;
  if public.tem_permissao(old.loja_id, 'cadastro.editar') then
    return new;
  end if;
  if new.loja_id is distinct from old.loja_id
     or new.user_id is distinct from old.user_id
     or new.cim is distinct from old.cim
     or new.data_iniciacao is distinct from old.data_iniciacao
     or new.data_elevacao is distinct from old.data_elevacao
     or new.data_exaltacao is distinct from old.data_exaltacao
     or new.situacao is distinct from old.situacao
     or new.observacoes is distinct from old.observacoes then
    raise exception 'Somente a Secretaria pode alterar esses campos do cadastro';
  end if;
  return new;
end $function$;

create or replace function public.proteger_inclusao_irmao()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return new;
  end if;
  if not public.tem_permissao(new.loja_id, 'graus.editar') then
    new.grau := 1;
    new.mestre_instalado := false;
  end if;
  if not private.e_veneravel(new.loja_id) then
    new.admin_loja := false;
  end if;
  new.admin_implantacao := false;
  return new;
end $function$;

-- Situação do meu acesso de administrador (faixa na tela de Gestão)
create function public.minha_administracao(p_loja uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'admin', i.admin_loja,
    'implantacao', i.admin_implantacao,
    'ativo', private.admin_ativo(p_loja, i.admin_loja, i.admin_implantacao),
    'tem_veneravel', private.tem_veneravel(p_loja),
    'sou_veneravel', private.e_veneravel(p_loja))
  from public.irmaos i
  where i.loja_id = p_loja and i.user_id = auth.uid()
  limit 1
$$;

-- Cargo já exercido: depois de 15 dias do cadastro, ou se o irmão já assinou documento nele, não se apaga nem se troca;
-- usa-se substituir_cargo. Cargo que ainda não começou (gestão futura) muda livremente.
create function private.mandato_travado(m public.mandatos) returns boolean
language sql stable security definer set search_path = '' as $$
  select m.inicio <= current_date and (
    m.criado_em < now() - interval '15 days'
    or exists (
      select 1 from public.documento_assinaturas a
      join public.loja_cargos c on c.id = m.cargo_id and c.codigo = a.cargo_codigo
      where a.loja_id = m.loja_id and a.irmao_id = m.irmao_id and a.assinado_em is not null
        and a.assinado_em::date between m.inicio and m.fim))
$$;

create function public.proteger_mandato() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' then
    new.criado_em := old.criado_em;
  end if;
  if private.mandato_travado(old) and (
       tg_op = 'DELETE'
       or new.irmao_id is distinct from old.irmao_id or new.cargo_id is distinct from old.cargo_id
       or new.inicio is distinct from old.inicio or new.fim is distinct from old.fim
       or new.gestao_id is distinct from old.gestao_id) then
    raise exception 'Cargo já exercido: para trocar o irmão, use Substituição (com data e motivo).';
  end if;
  return coalesce(new, old);
end $$;
create trigger proteger before update or delete on public.mandatos
  for each row execute function public.proteger_mandato();

-- Substituição: o atual sai em p_data − 1 e o novo (ou vago) assume em p_data até o fim do mandato
create function public.substituir_cargo(p_mandato uuid, p_irmao uuid, p_data date, p_motivo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  m public.mandatos;
  v_novo uuid;
begin
  select * into m from public.mandatos where id = p_mandato for update;
  if m.id is null or not public.tem_permissao(m.loja_id, 'cargos.editar') then
    raise exception 'Sem permissão para alterar cargos';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then
    raise exception 'Informe o motivo da substituição';
  end if;
  if p_data is null or p_data <= m.inicio or p_data > m.fim then
    raise exception 'A data da substituição precisa ficar dentro do mandato (depois de %)', to_char(m.inicio, 'DD/MM/YYYY');
  end if;
  if p_irmao is not null and not exists (
       select 1 from public.irmaos where id = p_irmao and loja_id = m.loja_id and situacao = 'ativo') then
    raise exception 'Irmão inválido';
  end if;
  if p_irmao = m.irmao_id then
    raise exception 'Escolha outro irmão';
  end if;

  perform set_config('malhete.sistema', 'on', true);
  update public.mandatos set fim = p_data - 1 where id = m.id;
  if p_irmao is not null then
    insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    values (m.loja_id, m.gestao_id, p_irmao, m.cargo_id, p_data, m.fim)
    returning id into v_novo;
  end if;
  perform set_config('malhete.sistema', 'off', true);

  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois)
  values (m.loja_id, 'mandatos', m.id, 'substituicao', to_jsonb(m),
          jsonb_build_object('novo_mandato', v_novo, 'irmao_id', p_irmao, 'data', p_data, 'motivo', trim(p_motivo)));
  return v_novo;
end $$;

revoke execute on function private.tem_veneravel(uuid), private.admin_ativo(uuid, boolean, boolean),
  private.e_veneravel(uuid), private.mandato_travado(public.mandatos) from public, anon;
grant execute on function private.tem_veneravel(uuid), private.admin_ativo(uuid, boolean, boolean),
  private.e_veneravel(uuid), private.mandato_travado(public.mandatos) to authenticated, service_role;
revoke execute on function public.minha_administracao(uuid), public.substituir_cargo(uuid, uuid, date, text) from public, anon;
grant execute on function public.minha_administracao(uuid), public.substituir_cargo(uuid, uuid, date, text) to authenticated;
revoke execute on function public.proteger_mandato() from public, anon, authenticated;
