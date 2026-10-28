-- Sistema Malhete — Hospitalaria também acompanha/ajuda instituições (asilo, orfanato, casa de apoio…).
alter table public.assistidos drop constraint assistidos_vinculo_check;
alter table public.assistidos add constraint assistidos_vinculo_check
  check (vinculo in ('irmao', 'viuva', 'familiar', 'instituicao', 'outro'));
alter table public.assistidos drop constraint assistidos_situacao_check;
alter table public.assistidos add constraint assistidos_situacao_check
  check (situacao in ('doente', 'internado', 'dificuldade', 'luto', 'idoso', 'acao_social', 'outro'));
