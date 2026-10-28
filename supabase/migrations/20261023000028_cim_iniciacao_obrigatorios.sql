-- Sistema Malhete — CIM e data de iniciação obrigatórios no cadastro do irmão.
-- Vale para irmãos novos e impede apagar esses dados depois. Cadastros antigos sem eles continuam
-- funcionando (o próprio irmão ainda atualiza telefone/endereço) até a Secretaria completar.
-- CIM não se repete dentro da mesma loja.

create function public.exigir_cim_iniciacao() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- sistema, ou quem cadastra a própria loja (criar_loja: completa a ficha depois em Editar)
  if current_setting('malhete.sistema', true) = 'on' or (tg_op = 'INSERT' and new.user_id = auth.uid()) then return new; end if;
  if tg_op = 'INSERT' or old.cim is not null or new.cim is distinct from old.cim then
    if nullif(trim(coalesce(new.cim, '')), '') is null then raise exception 'Informe o CIM do irmão'; end if;
  end if;
  if tg_op = 'INSERT' or old.data_iniciacao is not null then
    if new.data_iniciacao is null then raise exception 'Informe a data de iniciação do irmão'; end if;
  end if;
  if new.data_iniciacao > current_date then raise exception 'A data de iniciação não pode ser no futuro'; end if;
  new.cim := nullif(trim(new.cim), '');
  return new;
end $$;
create trigger exigir_cim_iniciacao before insert or update of cim, data_iniciacao on public.irmaos
for each row execute function public.exigir_cim_iniciacao();
revoke execute on function public.exigir_cim_iniciacao from public, anon, authenticated;

create unique index irmaos_loja_cim on public.irmaos (loja_id, cim) where cim is not null;
