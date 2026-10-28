-- Sistema Malhete — média de frequência da Loja no ano (para o irmão comparar a própria). Devolve só o número:
-- quem não é da Chancelaria continua sem ver a presença dos outros.
create function public.frequencia_media_loja(p_loja uuid, p_ano int) returns numeric
language sql stable security definer set search_path = '' as $$
  select round(avg(f.percentual), 1)
  from public.frequencia(p_loja, p_ano) f
  join public.irmaos i on i.id = f.irmao_id and i.situacao in ('ativo', 'licenciado')
  where f.percentual is not null and p_loja in (select public.minhas_lojas())
$$;
revoke execute on function public.frequencia_media_loja from public, anon;
grant execute on function public.frequencia_media_loja to authenticated;
