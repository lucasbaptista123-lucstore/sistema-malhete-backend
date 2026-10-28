-- Sistema Malhete — só o Venerável e o Secretário definem o grau (e Mestre Instalado) dos irmãos.
-- 'graus.editar' é explícita desses cargos (o '*' não basta, como nas exclusivas); o admin da loja
-- só a tem enquanto a gestão não tiver quem a tenha. Irmão incluído por quem não pode entra como
-- Aprendiz. Marcar alguém como administrador da loja: só quem configura a loja (Venerável/admin).

create or replace function public.permissoes_exclusivas() returns text[]
language sql immutable set search_path = '' as $$
  select array['tesouraria.editar', 'tronco.editar', 'chancelaria.editar', 'secretaria.editar', 'graus.editar']
$$;

update public.rito_cargos set permissoes = permissoes || array['graus.editar']
where codigo in ('veneravel', 'secretario') and not 'graus.editar' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['graus.editar']
where codigo in ('veneravel', 'secretario') and not 'graus.editar' = any (permissoes);

-- Inclusão: grau, Mestre Instalado e admin só pelo sistema (criar_loja) ou pelo Venerável.
create function public.proteger_inclusao_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return new;
  end if;
  if not public.tem_permissao(new.loja_id, 'graus.editar') then
    new.grau := 1;
    new.mestre_instalado := false;
  end if;
  if not public.tem_permissao(new.loja_id, 'loja.config') then
    new.admin_loja := false;
  end if;
  return new;
end $$;
create trigger proteger_inclusao before insert on public.irmaos
for each row execute function public.proteger_inclusao_irmao();

-- Alteração: grau/Mestre Instalado só Venerável; admin só quem configura a loja; o resto como antes.
create or replace function public.proteger_campos_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  if auth.uid() is null or current_setting('malhete.sistema', true) = 'on' then
    return new;
  end if;
  if (new.grau is distinct from old.grau or new.mestre_instalado is distinct from old.mestre_instalado)
     and not public.tem_permissao(old.loja_id, 'graus.editar') then
    raise exception 'Só o Venerável Mestre ou o Secretário alteram o grau do irmão';
  end if;
  if new.admin_loja is distinct from old.admin_loja and not public.tem_permissao(old.loja_id, 'loja.config') then
    raise exception 'Só o Venerável Mestre define o administrador da loja';
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

-- criar_loja grava o grau de quem cadastra a loja: marca como ação do sistema.
do $$
declare
  v_def text := pg_get_functiondef('public.criar_loja(text, text, uuid, uuid, text, character, text, smallint)'::regprocedure);
begin
  v_def := replace(v_def,
    '  insert into public.irmaos (loja_id, user_id, admin_loja, nome, email, grau)',
    '  perform set_config(''malhete.sistema'', ''on'', true);
  insert into public.irmaos (loja_id, user_id, admin_loja, nome, email, grau)');
  v_def := replace(v_def,
    '  insert into public.assinaturas (loja_id) values (v_loja);',
    '  perform set_config(''malhete.sistema'', ''off'', true);
  insert into public.assinaturas (loja_id) values (v_loja);');
  if position('malhete.sistema' in v_def) = 0 then raise exception 'criar_loja não ajustada'; end if;
  execute v_def;
end $$;

revoke execute on function public.proteger_inclusao_irmao from public, anon, authenticated;
