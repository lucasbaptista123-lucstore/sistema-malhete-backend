-- Sistema Malhete — catálogos iniciais: GOB, orientes estaduais, ritos e cargos do REAA.
-- Nomes dos orientes ficam genéricos (GOB-UF) e podem ser ajustados depois.

insert into public.potencias (sigla, nome) values ('GOB', 'Grande Oriente do Brasil');

insert into public.orientes (potencia_id, uf, nome)
select p.id, uf, 'GOB-' || uf
from public.potencias p,
  unnest(array['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA',
               'PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO']) as uf
where p.sigla = 'GOB';

insert into public.ritos (sigla, nome, ativo) values
  ('REAA', 'Rito Escocês Antigo e Aceito', true),
  ('MODERNO', 'Rito Moderno', false),
  ('BRASILEIRO', 'Rito Brasileiro', false),
  ('ADONHIRAMITA', 'Rito Adonhiramita', false),
  ('YORK', 'Rito de York', false),
  ('SCHRODER', 'Rito Schröder', false);

-- REAA: 2º Vigilante acompanha Aprendizes, 1º Vigilante acompanha Companheiros.
insert into public.rito_cargos (rito_id, codigo, nome, ordem, grau_acompanhado, permissoes)
select r.id, c.codigo, c.nome, c.ordem, c.grau, c.perms
from public.ritos r,
  (values
    ('veneravel',          'Venerável Mestre',      1, null::smallint, array['*']),
    ('primeiro_vigilante', '1º Vigilante',          2, 2::smallint,    array['cadastro.ler','trabalhos.avaliar','comunicacao.enviar']),
    ('segundo_vigilante',  '2º Vigilante',          3, 1::smallint,    array['cadastro.ler','trabalhos.avaliar','comunicacao.enviar']),
    ('orador',             'Orador',                4, null,           array['cadastro.ler','tesouraria.ler','tronco.ler','secretaria.ler','chancelaria.ler','auditoria.ler']),
    ('secretario',         'Secretário',            5, null,           array['cadastro.editar','cargos.editar','secretaria.editar','chancelaria.ler','comunicacao.enviar']),
    ('tesoureiro',         'Tesoureiro',            6, null,           array['cadastro.ler','tesouraria.editar','tronco.editar','secretaria.ler','comunicacao.enviar']),
    ('chanceler',          'Chanceler',             7, null,           array['cadastro.ler','chancelaria.editar','secretaria.ler','comunicacao.enviar']),
    ('mestre_cerimonias',  'Mestre de Cerimônias',  8, null,           array[]::text[]),
    ('hospitaleiro',       'Hospitaleiro',          9, null,           array['cadastro.ler','tronco.editar','secretaria.ler','comunicacao.enviar']),
    ('primeiro_diacono',   '1º Diácono',           10, null,           array[]::text[]),
    ('segundo_diacono',    '2º Diácono',           11, null,           array[]::text[]),
    ('primeiro_experto',   '1º Experto',           12, null,           array[]::text[]),
    ('segundo_experto',    '2º Experto',           13, null,           array[]::text[]),
    ('cobridor_interno',   'Cobridor Interno',     14, null,           array[]::text[]),
    ('cobridor_externo',   'Cobridor Externo',     15, null,           array[]::text[]),
    ('porta_estandarte',   'Porta-Estandarte',     16, null,           array[]::text[]),
    ('porta_espada',       'Porta-Espada',         17, null,           array[]::text[]),
    ('mestre_harmonia',    'Mestre de Harmonia',   18, null,           array[]::text[]),
    ('mestre_banquetes',   'Mestre de Banquetes',  19, null,           array[]::text[]),
    ('arquiteto',          'Arquiteto',            20, null,           array[]::text[]),
    ('bibliotecario',      'Bibliotecário',        21, null,           array[]::text[]),
    ('comissao_financas',  'Comissão de Finanças', 30, null,           array['tesouraria.ler','tronco.ler'])
  ) as c(codigo, nome, ordem, grau, perms)
where r.sigla = 'REAA';
