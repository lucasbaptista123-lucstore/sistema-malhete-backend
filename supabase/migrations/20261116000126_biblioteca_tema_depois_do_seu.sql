-- Sistema Malhete: TRABALHO DE TEMA SÓ DEPOIS DE FAZER O SEU (16/11, sugestão do 1º Vigilante da Orvalho, pelo Lucas:
-- "o irmão que ainda não fez o tema não pode ver o trabalho do outro, para não ter risco de cópia").
-- Na Biblioteca, o irmão do MESMO grau do tema só lê o trabalho de outro irmão sobre aquele tema depois que o dele,
-- sobre o mesmo tema, for APROVADO (enviado ou com ajustes pedidos ainda daria para copiar). Leem sempre: o autor,
-- quem avalia o grau (Vigilante do grau, Venerável, administrador) e quem já passou do grau. Trabalho sem tema
-- continua livre no grau. Na lista o trabalho aparece trancado (título, autor, tema), sem texto nem arquivo; o
-- arquivo também fica trancado no storage (e passa a abrir para quem pode, ver abaixo).

create function public.trabalho_liberado(p_trabalho uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trabalhos t
    where t.id = p_trabalho
      and (t.tema_id is null
           or t.irmao_id = public.meu_irmao_id(t.loja_id)
           or public.pode_avaliar(t.loja_id, t.grau)
           or public.meu_grau(t.loja_id) > t.grau
           or exists (select 1 from public.trabalhos m
                      where m.loja_id = t.loja_id and m.tema_id = t.tema_id and m.status = 'aprovado'
                        and m.irmao_id = public.meu_irmao_id(t.loja_id))))
$$;
revoke execute on function public.trabalho_liberado from public, anon;
grant execute on function public.trabalho_liberado to authenticated;

drop function public.trabalhos_aprovados(uuid);
create function public.trabalhos_aprovados(p_loja uuid)
returns table (id uuid, titulo text, autor text, grau smallint, tema text, texto text,
               arquivo_caminho text, arquivo_nome text, aprovado_em timestamptz,
               tema_id uuid, tema_ativo boolean, liberado boolean)
language sql stable security definer set search_path = '' as $$
  select x.id, x.titulo, x.autor, x.grau, x.tema,
         case when x.liberado then x.texto end,
         case when x.liberado then x.arquivo_caminho end,
         case when x.liberado then x.arquivo_nome end,
         x.aprovado_em, x.tema_id, x.tema_ativo, x.liberado
  from (
    select t.id, t.titulo, i.nome as autor, t.grau, tm.titulo as tema, t.texto, t.arquivo_caminho, t.arquivo_nome,
           coalesce(t.avaliado_em, t.enviado_em) as aprovado_em, t.tema_id, tm.ativo as tema_ativo,
           public.trabalho_liberado(t.id) as liberado
    from public.trabalhos t
    join public.irmaos i on i.id = t.irmao_id
    left join public.temas_trabalho tm on tm.id = t.tema_id
    where t.loja_id = p_loja and t.status = 'aprovado'
      and public.pode_ver_grau(p_loja, t.grau)
  ) x
  order by x.aprovado_em desc
$$;
revoke execute on function public.trabalhos_aprovados from public, anon;
grant execute on function public.trabalhos_aprovados to authenticated;

-- Arquivo da versão aprovada na Biblioteca: além do grau, precisa estar liberado. A checagem vai numa função
-- security definer: a política antiga consultava public.trabalhos com o RLS de quem lê, e o irmão que não é autor
-- nem avalia não enxerga a linha, então o arquivo do trabalho aprovado nunca abria na Biblioteca (só o texto).
create function public.arquivo_trabalho_liberado(p_nome text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trabalhos t
    where t.arquivo_caminho = p_nome and t.status = 'aprovado'
      and public.pode_ver_grau(t.loja_id, t.grau) and public.trabalho_liberado(t.id))
$$;
revoke execute on function public.arquivo_trabalho_liberado from public, anon;
grant execute on function public.arquivo_trabalho_liberado to authenticated;

drop policy trabalhos_le on storage.objects;
create policy trabalhos_le on storage.objects for select to authenticated
  using (bucket_id = 'trabalhos' and (
    exists (
      select 1 from public.trabalhos t
      where (t.arquivo_caminho = name or t.parecer_arquivo_caminho = name
             or exists (select 1 from public.trabalho_historico h where h.trabalho_id = t.id and h.arquivo_caminho = name))
        and (t.irmao_id = public.meu_irmao_id(t.loja_id) or public.pode_avaliar(t.loja_id, t.grau)))
    or public.arquivo_trabalho_liberado(name)));
