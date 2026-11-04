-- Importação do quadro do GOB (04/11, pedido do Lucas): o GOB não traz CPF, e-mail nem telefone.
-- CPF e e-mail deixam de ser obrigatórios no cadastro: se vierem, são conferidos; preenchidos, não se apagam.
-- Nome completo, CIM (ou CIM pendente) e data de iniciação continuam obrigatórios.
-- Quem fica sem CPF ou e-mail aparece como "Cadastro incompleto" (diretorio().faltando) até completar.

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

