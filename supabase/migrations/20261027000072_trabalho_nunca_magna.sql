-- Sistema Malhete: nenhum trabalho é lido em sessão magna (antes a trava era só para Aprendiz).
create or replace function public.validar_trabalho_sessao() returns trigger
language plpgsql security definer set search_path = '' as $$
declare s public.sessoes;
begin
  if new.lido_em_sessao_id is null or new.lido_em_sessao_id is not distinct from old.lido_em_sessao_id then return new; end if;
  if new.status <> 'aprovado' then raise exception 'Só trabalho aprovado é apresentado em sessão'; end if;
  select * into s from public.sessoes where id = new.lido_em_sessao_id;
  if s.id is null or s.loja_id <> new.loja_id then raise exception 'Sessão inválida'; end if;
  if s.status = 'cancelada' then raise exception 'Esta sessão foi cancelada'; end if;
  if s.grau <> new.grau then raise exception 'O trabalho só é lido em sessão do mesmo grau dele'; end if;
  if s.tipo = 'magna' then raise exception 'Trabalho não é lido em sessão magna'; end if;
  return new;
end $$;
