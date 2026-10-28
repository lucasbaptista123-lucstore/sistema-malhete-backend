-- Cargos dos ritos York, Schröder, Moderno, Adonhiramita e Brasileiro (28/10).
-- Parte ADMINISTRATIVA, igual em todo rito (Modelo de Estatuto das Lojas do GOB, art. 12 a 14): Venerável,
-- 1º e 2º Vigilantes, Secretário, Tesoureiro, Chanceler e Orador (rito sem Orador: membro eleito do
-- Ministério Público), Comissões obrigatórias de Finanças, Admissão e Graus e Beneficência. Os CÓDIGOS
-- dessas funções são os mesmos em todos os ritos (o sistema depende deles); o NOME segue o rito.
-- Oficiais RITUALÍSTICOS por rito:
--   York: Regra 104 do Livro das Constituições da Grande Loja Unida da Inglaterra (ordem de precedência).
--   Schröder: Ritual de Aprendiz do Rito Schröder do Grande Oriente do Paraná (GOB).
--   Adonhiramita: Ritual de Aprendiz Maçom do Rito Adonhiramita (GOB, 2009) e RGF.
--   Moderno e Brasileiro: Dignidades pelo ritual do GOB; demais oficiais por fontes secundárias (A CONFIRMAR).
-- Cada Loja ainda ajusta nomes, cria cargos extras e muda permissões (Cargos e permissões, 0063).

create temp table _p (k text primary key, perms text[]);
insert into _p values
  ('vm',  '{*,graus.editar,mural.publicar}'),
  ('vig', '{cadastro.ler,trabalhos.avaliar,comunicacao.enviar,biblioteca.editar}'),
  ('or',  '{cadastro.ler,tesouraria.ler,tronco.ler,secretaria.ler,chancelaria.ler,auditoria.ler,biblioteca.editar}'),
  ('sec', '{cadastro.editar,cargos.editar,secretaria.editar,chancelaria.ler,comunicacao.enviar,graus.editar}'),
  ('tes', '{cadastro.ler,tesouraria.editar,tronco.editar,secretaria.ler,comunicacao.enviar}'),
  ('cha', '{cadastro.ler,chancelaria.editar,secretaria.ler,comunicacao.enviar,sessoes.convocar}'),
  ('hos', '{cadastro.ler,tronco.ler,secretaria.ler,comunicacao.enviar,hospitalaria.editar,mural.publicar}'),
  ('cf',  '{tesouraria.ler,tronco.ler}'),
  ('ca',  '{cadastro.ler}'),
  ('cb',  '{tronco.ler}'),
  ('-',   '{}');

create temp table _c (sigla text, ordem int, codigo text, nome text, ga smallint, k text);
insert into _c values
  -- York (ordem de precedência da Regra 104(d)); Esmoler = Almoner (assistência, usa a Hospitalaria)
  ('YORK', 1, 'veneravel', 'Venerável Mestre', null, 'vm'),
  ('YORK', 2, 'primeiro_vigilante', '1º Vigilante', 2, 'vig'),
  ('YORK', 3, 'segundo_vigilante', '2º Vigilante', 1, 'vig'),
  ('YORK', 4, 'capelao', 'Capelão', null, '-'),
  ('YORK', 5, 'tesoureiro', 'Tesoureiro', null, 'tes'),
  ('YORK', 6, 'secretario', 'Secretário', null, 'sec'),
  ('YORK', 7, 'mestre_cerimonias', 'Diretor de Cerimônias', null, '-'),
  ('YORK', 8, 'hospitaleiro', 'Esmoler', null, 'hos'),
  ('YORK', 9, 'administrador_caridade', 'Administrador de Caridade', null, 'cb'),
  ('YORK', 10, 'oficial_membros', 'Oficial de Membros', null, '-'),
  ('YORK', 11, 'mentor', 'Mentor', null, '-'),
  ('YORK', 12, 'primeiro_diacono', '1º Diácono', null, '-'),
  ('YORK', 13, 'segundo_diacono', '2º Diácono', null, '-'),
  ('YORK', 14, 'assistente_cerimonias', 'Assistente do Diretor de Cerimônias', null, '-'),
  ('YORK', 15, 'organista', 'Organista', null, '-'),
  ('YORK', 16, 'assistente_secretario', 'Assistente do Secretário', null, '-'),
  ('YORK', 17, 'guarda_interno', 'Guarda Interno', null, '-'),
  ('YORK', 18, 'mordomo', 'Mordomo', null, '-'),
  ('YORK', 19, 'guarda_externo', 'Guarda Externo', null, '-'),
  ('YORK', 20, 'chanceler', 'Chanceler', null, 'cha'),
  ('YORK', 21, 'orador', 'Membro do Ministério Público', null, 'or'),
  -- Schröder (o Tronco circula pelo 2º Diácono; a assistência fica com a Comissão de Beneficência)
  ('SCHRODER', 1, 'veneravel', 'Venerável Mestre', null, 'vm'),
  ('SCHRODER', 2, 'primeiro_vigilante', '1º Vigilante', 2, 'vig'),
  ('SCHRODER', 3, 'segundo_vigilante', '2º Vigilante', 1, 'vig'),
  ('SCHRODER', 4, 'secretario', 'Secretário', null, 'sec'),
  ('SCHRODER', 5, 'tesoureiro', 'Tesoureiro', null, 'tes'),
  ('SCHRODER', 6, 'primeiro_diacono', '1º Diácono', null, '-'),
  ('SCHRODER', 7, 'segundo_diacono', '2º Diácono', null, '-'),
  ('SCHRODER', 8, 'guarda_templo', 'Guarda do Templo', null, '-'),
  ('SCHRODER', 9, 'mestre_harmonia', 'Mestre de Harmonia', null, '-'),
  ('SCHRODER', 10, 'preparador', 'Preparador', null, '-'),
  ('SCHRODER', 11, 'orador', 'Orador', null, 'or'),
  ('SCHRODER', 12, 'chanceler', 'Chanceler', null, 'cha'),
  ('SCHRODER', 13, 'hospitaleiro', 'Comissão de Beneficência', null, 'hos'),
  -- Adonhiramita
  ('ADONHIRAMITA', 1, 'veneravel', 'Venerável Mestre', null, 'vm'),
  ('ADONHIRAMITA', 2, 'primeiro_vigilante', '1º Vigilante', 2, 'vig'),
  ('ADONHIRAMITA', 3, 'segundo_vigilante', '2º Vigilante', 1, 'vig'),
  ('ADONHIRAMITA', 4, 'orador', 'Orador', null, 'or'),
  ('ADONHIRAMITA', 5, 'secretario', 'Secretário', null, 'sec'),
  ('ADONHIRAMITA', 6, 'tesoureiro', 'Tesoureiro', null, 'tes'),
  ('ADONHIRAMITA', 7, 'chanceler', 'Chanceler', null, 'cha'),
  ('ADONHIRAMITA', 8, 'mestre_cerimonias', 'Mestre de Cerimônias', null, '-'),
  ('ADONHIRAMITA', 9, 'hospitaleiro', 'Hospitaleiro', null, 'hos'),
  ('ADONHIRAMITA', 10, 'primeiro_experto', '1º Experto', null, '-'),
  ('ADONHIRAMITA', 11, 'segundo_experto', '2º Experto', null, '-'),
  ('ADONHIRAMITA', 12, 'cobridor_interno', 'Cobridor Interno', null, '-'),
  ('ADONHIRAMITA', 13, 'cobridor_externo', 'Cobridor Externo', null, '-'),
  ('ADONHIRAMITA', 14, 'arquiteto', 'Arquiteto', null, '-'),
  ('ADONHIRAMITA', 15, 'mestre_harmonia', 'Mestre de Harmonia', null, '-'),
  ('ADONHIRAMITA', 16, 'mestre_banquetes', 'Mestre de Banquetes', null, '-'),
  ('ADONHIRAMITA', 17, 'bibliotecario', 'Bibliotecário', null, '-'),
  ('ADONHIRAMITA', 18, 'porta_bandeira', 'Porta-Bandeira', null, '-'),
  ('ADONHIRAMITA', 19, 'porta_estandarte', 'Porta-Estandarte', null, '-'),
  -- Moderno (A CONFIRMAR com o ritual do GOB)
  ('MODERNO', 1, 'veneravel', 'Venerável Mestre', null, 'vm'),
  ('MODERNO', 2, 'primeiro_vigilante', '1º Vigilante', 2, 'vig'),
  ('MODERNO', 3, 'segundo_vigilante', '2º Vigilante', 1, 'vig'),
  ('MODERNO', 4, 'orador', 'Orador', null, 'or'),
  ('MODERNO', 5, 'secretario', 'Secretário', null, 'sec'),
  ('MODERNO', 6, 'tesoureiro', 'Tesoureiro', null, 'tes'),
  ('MODERNO', 7, 'chanceler', 'Chanceler', null, 'cha'),
  ('MODERNO', 8, 'mestre_cerimonias', 'Mestre de Cerimônias', null, '-'),
  ('MODERNO', 9, 'hospitaleiro', 'Hospitaleiro', null, 'hos'),
  ('MODERNO', 10, 'primeiro_experto', '1º Experto', null, '-'),
  ('MODERNO', 11, 'segundo_experto', '2º Experto', null, '-'),
  ('MODERNO', 12, 'guarda_templo', 'Guarda do Templo', null, '-'),
  ('MODERNO', 13, 'guarda_externo', 'Guarda Externo', null, '-'),
  ('MODERNO', 14, 'arquiteto', 'Arquiteto', null, '-'),
  ('MODERNO', 15, 'mestre_harmonia', 'Mestre de Harmonia', null, '-'),
  ('MODERNO', 16, 'mestre_banquetes', 'Mestre de Banquetes', null, '-'),
  ('MODERNO', 17, 'bibliotecario', 'Bibliotecário', null, '-'),
  ('MODERNO', 18, 'porta_estandarte', 'Porta-Estandarte', null, '-'),
  ('MODERNO', 19, 'porta_bandeira', 'Porta-Bandeira', null, '-'),
  -- Brasileiro (Dignidades conforme o ritual do GOB; demais A CONFIRMAR)
  ('BRASILEIRO', 1, 'veneravel', 'Venerável Mestre', null, 'vm'),
  ('BRASILEIRO', 2, 'primeiro_vigilante', '1º Vigilante', 2, 'vig'),
  ('BRASILEIRO', 3, 'segundo_vigilante', '2º Vigilante', 1, 'vig'),
  ('BRASILEIRO', 4, 'orador', 'Orador', null, 'or'),
  ('BRASILEIRO', 5, 'secretario', 'Secretário', null, 'sec'),
  ('BRASILEIRO', 6, 'tesoureiro', 'Tesoureiro', null, 'tes'),
  ('BRASILEIRO', 7, 'chanceler', 'Chanceler', null, 'cha'),
  ('BRASILEIRO', 8, 'mestre_cerimonias', 'Mestre de Cerimônias', null, '-'),
  ('BRASILEIRO', 9, 'hospitaleiro', 'Hospitaleiro', null, 'hos'),
  ('BRASILEIRO', 10, 'primeiro_experto', '1º Experto', null, '-'),
  ('BRASILEIRO', 11, 'segundo_experto', '2º Experto', null, '-'),
  ('BRASILEIRO', 12, 'guarda_templo', 'Guarda do Templo', null, '-'),
  ('BRASILEIRO', 13, 'cobridor_externo', 'Cobridor', null, '-'),
  ('BRASILEIRO', 14, 'porta_estandarte', 'Porta-Estandarte', null, '-'),
  ('BRASILEIRO', 15, 'porta_bandeira', 'Porta-Bandeira', null, '-'),
  ('BRASILEIRO', 16, 'mestre_harmonia', 'Mestre de Harmonia', null, '-'),
  ('BRASILEIRO', 17, 'mestre_banquetes', 'Mestre de Banquetes', null, '-'),
  ('BRASILEIRO', 18, 'arquiteto', 'Arquiteto', null, '-'),
  ('BRASILEIRO', 19, 'bibliotecario', 'Bibliotecário', null, '-');

-- Comissões obrigatórias do Estatuto do GOB, em todos os ritos (Schröder já usa a de Beneficência como "hospitaleiro")
insert into _c select s, o, c, n, null, k from (values ('YORK'), ('SCHRODER'), ('ADONHIRAMITA'), ('MODERNO'), ('BRASILEIRO'), ('REAA')) r(s)
  cross join (values (30, 'comissao_financas', 'Comissão de Finanças', 'cf'), (31, 'comissao_admissao', 'Comissão de Admissão e Graus', 'ca'),
                     (32, 'comissao_beneficencia', 'Comissão de Beneficência', 'cb')) x(o, c, n, k)
  where not (r.s = 'SCHRODER' and x.c = 'comissao_beneficencia');

insert into public.rito_cargos (rito_id, codigo, nome, ordem, grau_acompanhado, permissoes)
select r.id, c.codigo, c.nome, c.ordem, c.ga, p.perms
from _c c join public.ritos r on r.sigla = c.sigla join _p p on p.k = c.k
where not exists (select 1 from public.rito_cargos x where x.rito_id = r.id and x.codigo = c.codigo);

-- Lojas já criadas ganham as comissões que faltam
insert into public.loja_cargos (loja_id, rito_cargo_id, codigo, nome, ordem, grau_acompanhado, permissoes)
select l.id, rc.id, rc.codigo, rc.nome, rc.ordem, rc.grau_acompanhado, rc.permissoes
from public.lojas l join public.rito_cargos rc on rc.rito_id = l.rito_id
where rc.codigo in ('comissao_admissao', 'comissao_beneficencia')
  and not exists (select 1 from public.loja_cargos x where x.loja_id = l.id and x.codigo = rc.codigo);

update public.ritos set ativo = true where sigla in ('YORK', 'SCHRODER', 'ADONHIRAMITA', 'MODERNO', 'BRASILEIRO');
drop table _c;
drop table _p;
