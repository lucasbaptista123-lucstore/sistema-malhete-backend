-- Sistema Malhete: trabalho aprovado é PROGRAMADO para o tempo de estudos de uma sessão (qualquer sessão agendada,
-- não só a próxima). trabalhos.lido_em_sessao_id passa a significar "apresentado/apresentar na sessão": sessão
-- agendada = programado; realizada = apresentado. A convocação cita o trabalho e o autor recebe aviso.

create function public.validar_trabalho_sessao() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.sessoes;
begin
  if new.lido_em_sessao_id is null or new.lido_em_sessao_id is not distinct from old.lido_em_sessao_id then return new; end if;
  if new.status <> 'aprovado' then raise exception 'Só trabalho aprovado é apresentado em sessão'; end if;
  select * into s from public.sessoes where id = new.lido_em_sessao_id;
  if s.id is null or s.loja_id <> new.loja_id then raise exception 'Sessão inválida'; end if;
  if s.status = 'cancelada' then raise exception 'Esta sessão foi cancelada'; end if;
  if s.grau > new.grau then raise exception 'A sessão é de grau acima do trabalho'; end if;
  return new;
end $$;
create trigger validar_sessao before update of lido_em_sessao_id on public.trabalhos
for each row execute function public.validar_trabalho_sessao();

-- avisa o autor quando o trabalho é programado para uma sessão futura
create function private.aviso_trabalho_programado() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.sessoes; v_nome text;
begin
  if new.lido_em_sessao_id is null or new.lido_em_sessao_id is not distinct from old.lido_em_sessao_id then return null; end if;
  select * into s from public.sessoes where id = new.lido_em_sessao_id;
  if s.status <> 'agendada' or s.data < current_date then return null; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'trabalho_avaliado', new.id,
    format('Olá, %s! Seu trabalho “%s” foi programado para o tempo de estudos da sessão de %s%s. Prepare a apresentação.',
           private.primeiro_nome(v_nome), new.titulo, to_char(s.data, 'DD/MM'), coalesce(' às ' || to_char(s.hora, 'HH24:MI'), '')));
  return null;
end $$;
create trigger aviso_programado after update of lido_em_sessao_id on public.trabalhos
for each row execute function private.aviso_trabalho_programado();
revoke execute on function public.validar_trabalho_sessao, private.aviso_trabalho_programado from public, anon, authenticated;

-- trabalhos do tempo de estudos de uma sessão (para convocação, pauta e tela da sessão)
create function public.trabalhos_da_sessao(p_sessao uuid)
returns table (id uuid, titulo text, autor text, grau smallint)
language sql stable security definer set search_path = '' as $$
  select t.id, t.titulo, i.nome, t.grau
  from public.trabalhos t join public.irmaos i on i.id = t.irmao_id join public.sessoes s on s.id = t.lido_em_sessao_id
  where t.lido_em_sessao_id = p_sessao and t.status = 'aprovado'
    and s.loja_id in (select public.minhas_lojas())
    and (public.pode_ver_grau(s.loja_id, s.grau) or public.tem_permissao(s.loja_id, 'chancelaria.ler'))
  order by t.titulo
$$;
revoke execute on function public.trabalhos_da_sessao from public, anon;
grant execute on function public.trabalhos_da_sessao to authenticated;
