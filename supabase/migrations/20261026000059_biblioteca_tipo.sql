-- Sistema Malhete — Biblioteca: tipo do material (livro, revista, artigo, vídeo, podcast, instrução), para filtrar
-- e para tocar vídeo/podcast dentro do sistema (o link continua no campo link).
alter table public.biblioteca add column tipo text not null default 'outro'
  check (tipo in ('livro', 'revista', 'artigo', 'video', 'podcast', 'instrucao', 'outro'));
update public.biblioteca set tipo = case
  when link ~* '(youtube\.com|youtu\.be|vimeo\.com)' then 'video'
  when link ~* '(spotify\.com|podcasts\.apple\.com|anchor\.fm)' then 'podcast'
  else 'outro' end;
