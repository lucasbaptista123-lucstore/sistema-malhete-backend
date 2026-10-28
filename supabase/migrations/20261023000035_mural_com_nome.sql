-- Sistema Malhete — aviso do mural pelo WhatsApp chama cada irmão pelo primeiro nome.

create or replace function public.mural_whatsapp(p_aviso uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  a public.mural;
  n int;
begin
  select * into a from public.mural where id = p_aviso;
  if a.id is null or not public.tem_permissao(a.loja_id, 'mural.publicar') then raise exception 'Sem permissão'; end if;
  if a.pelo_whatsapp then raise exception 'Este aviso já foi enviado pelo WhatsApp'; end if;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select a.loja_id, i.id, 'mural', a.id,
         format('Irmão %s,%s*%s*%s', private.primeiro_nome(i.nome), E'\n\n', a.titulo, coalesce(E'\n\n' || nullif(trim(a.texto), ''), '')),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = a.loja_id and i.situacao in ('ativo', 'licenciado') and i.grau >= a.grau_minimo;
  get diagnostics n = row_count;
  update public.mural set pelo_whatsapp = true where id = a.id;
  return n;
end $$;
