-- Administrador com acesso TOTAL por exceção (09/11, Lucas na Orvalho: "estou com acesso total e não consegui
-- alterar o dado de um irmão"). O administrador comum não recebe as permissões exclusivas de cargo (grau,
-- Secretaria, Chancelaria, Tesouraria, Tronco) quando há quem ocupe o cargo, e na Orvalho o Venerável e o
-- Secretário estão nomeados, mas ainda não usam o sistema.
-- irmaos.admin_total = true dá também essas permissões, enquanto ele for administrador ativo.
-- Só se liga por script (Management API, sem usuário logado), nunca pela tela e nunca pelo painel do dono.
-- Exceção só da Orvalho (Loja do próprio Lucas, que conduz a implantação). Não usar em outras Lojas.
alter table public.irmaos add column if not exists admin_total boolean not null default false;

create or replace function private.tem_permissao_base(p_loja uuid, p_perm text)
returns boolean language sql stable security definer set search_path = '' as $$
  with exclusiva as (
    select p_perm = any (public.permissoes_exclusivas()) as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo' and private.mfa_ok()
      and (
        (private.admin_ativo(p_loja, i.admin_loja, i.admin_implantacao) and (
           not x.sim
           or i.admin_total
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
$$;

create or replace function public.proteger_campos_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return new;
  end if;
  if new.admin_total is distinct from old.admin_total then
    raise exception 'Este acesso não se altera pela tela';
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
end $$;

-- novo irmão não nasce com acesso total
create or replace function private.sem_admin_total_na_inclusao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then new.admin_total := false; end if;
  return new;
end $$;
drop trigger if exists sem_admin_total on public.irmaos;
create trigger sem_admin_total before insert on public.irmaos
  for each row execute function private.sem_admin_total_na_inclusao();
