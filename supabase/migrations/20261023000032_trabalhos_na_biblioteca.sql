-- Sistema Malhete — trabalho aprovado vai para a biblioteca do grau: Aprendiz vê os de Aprendiz,
-- Companheiro os de Aprendiz e Companheiro, Mestre todos (pelo grau do cadastro, pode_ver_grau).
-- Antes da aprovação só o autor e quem avalia veem. Ressalvas e histórico continuam privados.

create function public.trabalhos_aprovados(p_loja uuid)
returns table (id uuid, titulo text, autor text, grau smallint, tema text, texto text,
               arquivo_caminho text, arquivo_nome text, aprovado_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select t.id, t.titulo, i.nome, t.grau, tm.titulo, t.texto, t.arquivo_caminho, t.arquivo_nome,
         coalesce(t.avaliado_em, t.enviado_em)
  from public.trabalhos t
  join public.irmaos i on i.id = t.irmao_id
  left join public.temas_trabalho tm on tm.id = t.tema_id
  where t.loja_id = p_loja and t.status = 'aprovado'
    and public.pode_ver_grau(p_loja, t.grau)
  order by coalesce(t.avaliado_em, t.enviado_em) desc
$$;
revoke execute on function public.trabalhos_aprovados from public, anon;
grant execute on function public.trabalhos_aprovados to authenticated;

drop policy trabalhos_le on storage.objects;
create policy trabalhos_le on storage.objects for select to authenticated
  using (bucket_id = 'trabalhos' and exists (
    select 1 from public.trabalhos t
    where (
      ((t.arquivo_caminho = name or t.parecer_arquivo_caminho = name
        or exists (select 1 from public.trabalho_historico h where h.trabalho_id = t.id and h.arquivo_caminho = name))
       and (t.irmao_id = public.meu_irmao_id(t.loja_id) or public.pode_avaliar(t.loja_id, t.grau)))
      -- aprovado: a versão final fica na biblioteca do grau
      or (t.status = 'aprovado' and t.arquivo_caminho = name and public.pode_ver_grau(t.loja_id, t.grau))
    )));
