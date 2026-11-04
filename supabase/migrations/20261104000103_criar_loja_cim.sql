-- Quem cadastra a Loja informa o próprio CIM (04/11): o cadastro do fundador já nasce com CIM, e a importação do
-- quadro da Potência reconhece o irmão pelo CIM (completa o que falta) em vez de criar outro cadastro dele.
drop function if exists public.criar_loja(text, text, uuid, uuid, text, character, text, smallint);

create function public.criar_loja(p_nome text, p_numero text, p_oriente_id uuid, p_rito_id uuid, p_cidade text, p_uf character, p_meu_nome text, p_meu_grau smallint default 3, p_meu_cim text default null)
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
  insert into public.irmaos (loja_id, user_id, admin_loja, admin_implantacao, nome, email, grau, cim)
  values (v_loja, auth.uid(), true, true, p_meu_nome,
          (select email from auth.users where id = auth.uid()), p_meu_grau,
          nullif(trim(coalesce(p_meu_cim, '')), ''));

  perform set_config('malhete.sistema', 'off', true);
  insert into public.assinaturas (loja_id) values (v_loja);

  return v_loja;
end $function$;

revoke execute on function public.criar_loja(text, text, uuid, uuid, text, character, text, smallint, text) from public, anon;
grant execute on function public.criar_loja(text, text, uuid, uuid, text, character, text, smallint, text) to authenticated;
