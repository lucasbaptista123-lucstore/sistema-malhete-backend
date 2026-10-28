-- Sistema Malhete — diretório mostra CIM e data de iniciação (tempo de maçonaria na lista de irmãos).
drop function public.diretorio(uuid);
create function public.diretorio(p_loja uuid)
returns table (id uuid, nome text, grau smallint, mestre_instalado boolean, situacao public.situacao_irmao,
               tem_acesso boolean, convidado_em timestamptz, cim text, data_iniciacao date)
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.grau, i.mestre_instalado, i.situacao, i.user_id is not null,
         (select max(c.criado_em) from public.convites c where c.irmao_id = i.id and c.usado_em is null and c.expira_em > now()),
         i.cim, i.data_iniciacao
  from public.irmaos i
  where i.loja_id = p_loja
    and p_loja in (select public.minhas_lojas())
  order by i.nome
$$;
revoke execute on function public.diretorio from public, anon;
grant execute on function public.diretorio to authenticated;
