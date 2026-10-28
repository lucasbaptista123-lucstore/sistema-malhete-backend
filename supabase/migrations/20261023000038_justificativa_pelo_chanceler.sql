-- Sistema Malhete — justificativa registrada pelo Chanceler (o irmão avisou pessoalmente) também vai ao Venerável.
-- Evita duplicar: se a justificativa veio do "não vou" com motivo (confirmacoes), ela já está na lista por lá.

create or replace function public.avisar_justificativa_presenca() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.situacao = 'justificada' and new.ciente_em is null and new.justificativa is not null
     and (tg_op = 'INSERT' or new.justificativa is distinct from old.justificativa or old.situacao <> 'justificada')
     and not exists (select 1 from public.confirmacoes c where c.sessao_id = new.sessao_id and c.irmao_id = new.irmao_id
                     and c.resposta = 'nao_vou' and c.motivo is not null) then
    perform private.avisar_veneravel(new.loja_id, new.sessao_id, new.irmao_id, new.justificativa, false);
  end if;
  return null;
end $$;

create or replace function public.justificativas(p_loja uuid, p_todas boolean default false)
returns table (origem text, id uuid, sessao_id uuid, sessao_data date, irmao_id uuid, irmao text, texto text,
               via text, enviada_em timestamptz, ciente_em timestamptz, aceita boolean, parecer text)
language sql stable security definer set search_path = '' as $$
  select * from (
    select 'confirmacao'::text as origem, c.id, c.sessao_id, s.data as sessao_data, c.irmao_id, i.nome as irmao,
           c.motivo as texto, c.canal as via, c.respondido_em as enviada_em, c.ciente_em, c.aceita, c.parecer
    from public.confirmacoes c join public.sessoes s on s.id = c.sessao_id join public.irmaos i on i.id = c.irmao_id
    where c.loja_id = p_loja and c.resposta = 'nao_vou' and c.motivo is not null
    union all
    select 'presenca', p.id, p.sessao_id, s.data, p.irmao_id, i.nome, p.justificativa,
           case when p.justificada_pelo_irmao then p.justificada_via else 'chanceler' end, p.registrado_em,
           p.ciente_em, p.aceita, p.parecer
    from public.presencas p join public.sessoes s on s.id = p.sessao_id join public.irmaos i on i.id = p.irmao_id
    where p.loja_id = p_loja and p.justificativa is not null
      and (p.situacao = 'justificada' or p.aceita = false)
      and not exists (select 1 from public.confirmacoes c where c.sessao_id = p.sessao_id and c.irmao_id = p.irmao_id
                      and c.resposta = 'nao_vou' and c.motivo is not null)
  ) x
  where (public.tem_permissao(p_loja, 'loja.config') or public.tem_permissao(p_loja, 'chancelaria.ler'))
    and (p_todas or x.ciente_em is null)
  order by x.enviada_em desc
  limit 300
$$;
