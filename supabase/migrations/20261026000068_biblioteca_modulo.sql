-- Sistema Malhete: módulo BIBLIOTECA. Reúne, por grau: trabalhos aprovados (automático, já existia), ATAS APROVADAS
-- (agora todo irmão do grau lê; a Secretaria pode tirar uma ata da Biblioteca) e documentos/estudos publicados
-- (novo tipo "documento": regimento, estatuto, decretos, atos).

alter table public.atas add column na_biblioteca boolean not null default true;

CREATE OR REPLACE FUNCTION public.validar_ata()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.sessoes;
begin
  if tg_op = 'DELETE' then
    if old.status = 'aprovada' and not old.importada then raise exception 'Ata aprovada não pode ser apagada'; end if;
    return old;
  end if;
  if new.arquivo_caminho is not null and public.loja_do_caminho(new.arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  if new.sessao_id is not null then
    select * into s from public.sessoes where id = new.sessao_id;
    if s.loja_id <> new.loja_id then raise exception 'Sessão de outra loja'; end if;
  end if;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('ata' || new.loja_id::text));
    new.numero := coalesce((select max(numero) from public.atas where loja_id = new.loja_id), 0) + 1;
    new.criado_por := auth.uid();
    new.criado_em := now();
    if new.sessao_id is null then
      -- ata antiga importada: já vem aprovada (é o registro oficial da época)
      if new.data_sessao is null or new.grau is null then raise exception 'Informe a data e o grau da ata'; end if;
      if coalesce(trim(new.texto), '') = '' and new.arquivo_caminho is null then raise exception 'Anexe o arquivo ou cole o texto da ata'; end if;
      new.importada := true;
      new.status := 'aprovada';
      new.aprovada_em := coalesce(new.aprovada_em, new.data_sessao);
    else
      new.importada := false;
      new.status := 'rascunho';
      new.data_sessao := s.data;
    end if;
  else
    -- liberar/recolher para leitura é permitido mesmo aprovada
    if old.status = 'aprovada' and (to_jsonb(new) - 'para_leitura' - 'na_biblioteca' - 'atualizado_em') <> (to_jsonb(old) - 'para_leitura' - 'na_biblioteca' - 'atualizado_em') then
      raise exception 'Ata aprovada não pode ser alterada';
    end if;
    if new.numero is distinct from old.numero or new.sessao_id is distinct from old.sessao_id or new.importada is distinct from old.importada then
      raise exception 'Número e sessão da ata não mudam';
    end if;
    if new.status = 'aprovada' and new.aprovada_em_sessao_id is not null
       and not exists (select 1 from public.sessoes where id = new.aprovada_em_sessao_id and loja_id = new.loja_id) then
      raise exception 'Sessão de aprovação inválida';
    end if;
  end if;
  if new.sessao_id is not null then new.grau := s.grau; end if;
  new.atualizado_em := now();
  return new;
end $function$;

-- irmão do grau lê ata aprovada que está na Biblioteca (além das liberadas para leitura antes da ratificação)
create policy biblioteca_atas on public.atas for select to authenticated
  using (status = 'aprovada' and na_biblioteca and loja_id in (select public.minhas_lojas())
         and (select public.pode_ver_grau(loja_id, grau)));
create policy biblioteca_ata_arquivo on storage.objects for select to authenticated
  using (bucket_id = 'secretaria' and exists (
    select 1 from public.atas a
    where a.arquivo_caminho = name and a.status = 'aprovada' and a.na_biblioteca
      and a.loja_id in (select public.minhas_lojas()) and public.pode_ver_grau(a.loja_id, a.grau)));

alter table public.biblioteca drop constraint biblioteca_tipo_check;
alter table public.biblioteca add constraint biblioteca_tipo_check
  check (tipo in ('documento', 'livro', 'revista', 'artigo', 'video', 'podcast', 'instrucao', 'outro'));
