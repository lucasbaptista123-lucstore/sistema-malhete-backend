-- Sistema Malhete: nome completo, CPF, e-mail, CIM e data de iniciação são obrigatórios no cadastro do irmão.
-- Exceção: Aprendiz recém-iniciado com o CIM ainda não emitido pela Potência (irmaos.cim_pendente).
-- Vale para irmãos novos; nos antigos, nada já preenchido pode ser apagado e formato inválido é recusado.
-- Fundador em criar_loja continua liberado (completa depois em Editar). Iniciação pela Admissão marca cim_pendente.

alter table public.irmaos add column cim_pendente boolean not null default false;

create function private.cpf_valido(p text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  for k in 0..1 loop
    s := 0;
    for i in 1..9 + k loop s := s + substr(d, i, 1)::int * (11 + k - i); end loop;
    r := (s * 10) % 11;
    if r = 10 then r := 0; end if;
    if r <> substr(d, 10 + k, 1)::int then return false; end if;
  end loop;
  return true;
end $$;

create function private.email_valido(p text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p, '') ~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'
$$;

create or replace function public.exigir_cim_iniciacao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- normaliza sempre
  new.nome := regexp_replace(trim(new.nome), '\s+', ' ', 'g');
  new.cim := nullif(trim(coalesce(new.cim, '')), '');
  new.cpf := nullif(regexp_replace(coalesce(new.cpf, ''), '\D', '', 'g'), '');
  new.email := nullif(lower(trim(coalesce(new.email, ''))), '');
  if new.cim is not null then new.cim_pendente := false; end if;

  -- sistema (Admissão, importações internas): Aprendiz sem CIM fica marcado como pendente
  if current_setting('malhete.sistema', true) = 'on' then
    if tg_op = 'INSERT' and new.cim is null and new.grau = 1 then new.cim_pendente := true; end if;
    return new;
  end if;
  -- quem cadastra a própria loja (criar_loja): completa a ficha depois em Editar
  if tg_op = 'INSERT' and new.user_id = auth.uid() then return new; end if;

  if new.cim_pendente and new.grau > 1 then
    raise exception 'CIM pendente só vale para Aprendiz recém-iniciado. Informe o CIM';
  end if;

  if tg_op = 'INSERT' then
    if new.nome !~ '\S+\s+\S+' then raise exception 'Informe o nome completo do irmão'; end if;
    if new.cpf is null then raise exception 'Informe o CPF do irmão'; end if;
    if new.email is null then raise exception 'Informe o e-mail do irmão'; end if;
    if new.cim is null and not new.cim_pendente then raise exception 'Informe o CIM do irmão (ou marque que ainda não foi emitido)'; end if;
    if new.data_iniciacao is null then raise exception 'Informe a data de iniciação do irmão'; end if;
  else
    -- não apaga o que já existe
    if old.cpf is not null and new.cpf is null then raise exception 'O CPF não pode ficar em branco'; end if;
    if old.email is not null and new.email is null then raise exception 'O e-mail não pode ficar em branco'; end if;
    if old.cim is not null and new.cim is null then raise exception 'Informe o CIM do irmão'; end if;
    if old.data_iniciacao is not null and new.data_iniciacao is null then raise exception 'Informe a data de iniciação do irmão'; end if;
    if new.nome is distinct from old.nome and new.nome !~ '\S+\s+\S+' then raise exception 'Informe o nome completo do irmão'; end if;
  end if;
  if new.cpf is not null and new.cpf is distinct from (case when tg_op = 'UPDATE' then old.cpf end)
     and not private.cpf_valido(new.cpf) then
    raise exception 'CPF inválido. Confira os números';
  end if;
  if new.email is not null and new.email is distinct from (case when tg_op = 'UPDATE' then old.email end)
     and not private.email_valido(new.email) then
    raise exception 'E-mail inválido';
  end if;
  if new.data_iniciacao > current_date then raise exception 'A data de iniciação não pode ser no futuro'; end if;
  return new;
end $$;

drop trigger exigir_cim_iniciacao on public.irmaos;
create trigger exigir_cim_iniciacao before insert or update of nome, cim, cpf, email, data_iniciacao, cim_pendente, grau on public.irmaos
for each row execute function public.exigir_cim_iniciacao();
revoke execute on function public.exigir_cim_iniciacao from public, anon, authenticated;
revoke execute on function private.cpf_valido, private.email_valido from public, anon;
grant execute on function private.cpf_valido, private.email_valido to authenticated;

-- lista de irmãos mostra o que falta no cadastro
drop function public.diretorio(uuid);
create function public.diretorio(p_loja uuid)
returns table (id uuid, nome text, grau smallint, mestre_instalado boolean, situacao public.situacao_irmao,
               tem_acesso boolean, convidado_em timestamptz, cim text, data_iniciacao date, foto_caminho text,
               cim_pendente boolean, faltando text[])
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.grau, i.mestre_instalado, i.situacao, i.user_id is not null,
         (select max(c.criado_em) from public.convites c where c.irmao_id = i.id and c.usado_em is null and c.expira_em > now()),
         i.cim, i.data_iniciacao, i.foto_caminho, i.cim_pendente,
         case when public.tem_permissao(p_loja, 'cadastro.ler') then array_remove(array[
           case when i.nome !~ '\S+\s+\S+' then 'nome completo' end,
           case when i.cpf is null then 'CPF' end,
           case when i.email is null then 'e-mail' end,
           case when i.cim is null and not i.cim_pendente then 'CIM' end,
           case when i.data_iniciacao is null then 'data de iniciação' end], null) else '{}' end
  from public.irmaos i
  where i.loja_id = p_loja
    and p_loja in (select public.minhas_lojas())
  order by i.nome
$$;
revoke execute on function public.diretorio from public, anon;
grant execute on function public.diretorio to authenticated;
