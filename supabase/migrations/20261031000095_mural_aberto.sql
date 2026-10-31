-- Mural aberto aos irmãos (31/10, decisão do Lucas): qualquer irmão publica DIRETO, para o próprio grau ou abaixo,
-- sem WhatsApp e sem fixar no topo (isso continua com quem tem mural.publicar: Venerável e Hospitaleiro).
-- O autor edita e apaga o que publicou; Venerável e Secretário apagam qualquer publicação.
alter table public.mural add column autor_id uuid references public.irmaos(id);
create index on public.mural (autor_id);
update public.mural m set autor_id = i.id from public.irmaos i where i.user_id = m.publicado_por and i.loja_id = m.loja_id and m.autor_id is null;

create function private.mural_autor() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.autor_id := coalesce(new.autor_id, public.meu_irmao_id(new.loja_id));
  return new;
end $$;
create trigger autor before insert on public.mural for each row execute function private.mural_autor();

drop policy publica on public.mural;
drop policy edita on public.mural;
drop policy apaga on public.mural;
create policy publica on public.mural for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'mural.publicar'))
              or ((select public.pode_ver_grau(loja_id, grau_minimo)) and not fixado and not pelo_whatsapp
                  and publicado_por = (select auth.uid())));
create policy edita on public.mural for update to authenticated
  using ((select public.tem_permissao(loja_id, 'mural.publicar')) or publicado_por = (select auth.uid()))
  with check ((select public.tem_permissao(loja_id, 'mural.publicar'))
              or ((select public.pode_ver_grau(loja_id, grau_minimo)) and not fixado and not pelo_whatsapp
                  and publicado_por = (select auth.uid())));
create policy apaga on public.mural for delete to authenticated
  using ((select public.tem_permissao(loja_id, 'mural.publicar')) or (select public.tem_permissao(loja_id, 'secretaria.editar'))
         or (select public.tem_permissao(loja_id, 'loja.config')) or publicado_por = (select auth.uid()));
