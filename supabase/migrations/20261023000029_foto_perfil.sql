-- Sistema Malhete — foto de perfil do irmão. Bucket privado 'fotos' (<loja>/<irmao>/<arquivo>):
-- todos da loja veem; o próprio irmão ou a Secretaria trocam. Diretório passa a trazer o caminho.

alter table public.irmaos add column foto_caminho text;
alter table public.irmaos add constraint foto_do_proprio
  check (foto_caminho is null or foto_caminho like loja_id::text || '/' || id::text || '/%');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create function public.pode_mudar_foto(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_loja uuid := public.loja_do_caminho(p_nome);
  v_irmao uuid;
begin
  begin v_irmao := split_part(p_nome, '/', 2)::uuid; exception when others then return false; end;
  return v_loja is not null and v_irmao is not null
    and exists (select 1 from public.irmaos where id = v_irmao and loja_id = v_loja)
    and (v_irmao = public.meu_irmao_id(v_loja) or public.tem_permissao(v_loja, 'cadastro.editar'));
end $$;
revoke execute on function public.pode_mudar_foto from public, anon;
grant execute on function public.pode_mudar_foto to authenticated;

create policy fotos_le on storage.objects for select to authenticated
  using (bucket_id = 'fotos' and public.loja_do_caminho(name) in (select public.minhas_lojas()));
create policy fotos_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.pode_mudar_foto(name));
create policy fotos_troca on storage.objects for update to authenticated
  using (bucket_id = 'fotos' and public.pode_mudar_foto(name))
  with check (bucket_id = 'fotos' and public.pode_mudar_foto(name));
create policy fotos_apaga on storage.objects for delete to authenticated
  using (bucket_id = 'fotos' and public.pode_mudar_foto(name));

drop function public.diretorio(uuid);
create function public.diretorio(p_loja uuid)
returns table (id uuid, nome text, grau smallint, mestre_instalado boolean, situacao public.situacao_irmao,
               tem_acesso boolean, convidado_em timestamptz, cim text, data_iniciacao date, foto_caminho text)
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.grau, i.mestre_instalado, i.situacao, i.user_id is not null,
         (select max(c.criado_em) from public.convites c where c.irmao_id = i.id and c.usado_em is null and c.expira_em > now()),
         i.cim, i.data_iniciacao, i.foto_caminho
  from public.irmaos i
  where i.loja_id = p_loja
    and p_loja in (select public.minhas_lojas())
  order by i.nome
$$;
revoke execute on function public.diretorio from public, anon;
grant execute on function public.diretorio to authenticated;
