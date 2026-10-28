-- Sistema Malhete: estandarte (imagem) da Loja, mostrado no topo do sistema e nos documentos impressos.
-- Arquivo no bucket privado 'fotos' em <loja>/loja/estandarte-<ts>.<ext>; todos da Loja leem (policy fotos_le),
-- só quem administra a Loja (loja.config) envia/troca.
alter table public.lojas add column estandarte_caminho text;

create function public.pode_mudar_estandarte(p_nome text) returns boolean
language sql stable security definer set search_path = '' as $$
  select split_part(p_nome, '/', 2) = 'loja' and public.loja_do_caminho(p_nome) is not null
     and public.tem_permissao(public.loja_do_caminho(p_nome), 'loja.config')
$$;
revoke execute on function public.pode_mudar_estandarte from public, anon;
grant execute on function public.pode_mudar_estandarte to authenticated;

create policy estandarte_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.pode_mudar_estandarte(name));
create policy estandarte_troca on storage.objects for update to authenticated
  using (bucket_id = 'fotos' and public.pode_mudar_estandarte(name))
  with check (bucket_id = 'fotos' and public.pode_mudar_estandarte(name));
create policy estandarte_apaga on storage.objects for delete to authenticated
  using (bucket_id = 'fotos' and public.pode_mudar_estandarte(name));

-- o caminho gravado na loja tem de ser da própria loja
create function public.validar_estandarte() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.estandarte_caminho is not null and (public.loja_do_caminho(new.estandarte_caminho) is distinct from new.id
     or split_part(new.estandarte_caminho, '/', 2) <> 'loja') then
    raise exception 'Imagem inválida para esta Loja';
  end if;
  return new;
end $$;
create trigger validar_estandarte before insert or update of estandarte_caminho on public.lojas
for each row execute function public.validar_estandarte();
revoke execute on function public.validar_estandarte from public, anon, authenticated;
