-- Onde cada assinante põe o selo do gov.br: o PDF base reserva um bloco por assinante (cargo + nome);
-- a função `assinaturas` recusa o selo colocado no bloco de OUTRO assinante (ex.: assinar na vez do
-- Tesoureiro em cima da linha do Venerável). Documentos antigos (sem área) não são conferidos.
alter table public.documento_assinaturas add column area jsonb;

drop function public.definir_pdf_base(uuid, text);
create function public.definir_pdf_base(p_doc uuid, p_caminho text, p_areas jsonb default null) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos; v_vez uuid; ar jsonb;
begin
  select * into d from public.documentos_emitidos where id = p_doc for update;
  if d.id is null or not (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.editar')) then
    raise exception 'Sem permissão';
  end if;
  if d.arquivo_base is not null then raise exception 'O PDF deste documento já foi gerado'; end if;
  if public.loja_do_caminho(p_caminho) is distinct from d.loja_id or split_part(p_caminho, '/', 3) <> d.id::text then
    raise exception 'Caminho inválido';
  end if;
  update public.documentos_emitidos set arquivo_base = p_caminho, arquivo_atual = p_caminho where id = d.id;
  if jsonb_typeof(p_areas) = 'array' then
    for ar in select * from jsonb_array_elements(p_areas) loop
      update public.documento_assinaturas
      set area = jsonb_build_object('pagina', (ar->>'pagina')::int, 'x1', (ar->>'x1')::numeric, 'y1', (ar->>'y1')::numeric,
                                    'x2', (ar->>'x2')::numeric, 'y2', (ar->>'y2')::numeric)
      where documento_id = d.id and ordem = (ar->>'ordem')::int;
    end loop;
  end if;
  select id into v_vez from public.documento_assinaturas where documento_id = d.id and status = 'vez';
  if v_vez is not null then perform private.avisar_assinante(v_vez); end if;
end $$;
revoke execute on function public.definir_pdf_base from public, anon;
grant execute on function public.definir_pdf_base to authenticated;
