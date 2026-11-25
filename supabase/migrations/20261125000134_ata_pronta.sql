-- Sistema Malhete: A ATA NASCE PRONTA (25/11, pedido do Lucas). A "Nova ata" abria em branco e o "Preencher com o
-- modelo" só trazia a contagem de presentes. Agora o rascunho sai do que a sessão já registrou:
-- abertura (data, hora, local, Loja, Oriente, tipo e grau da sessão, quem presidia e os Vigilantes no cargo naquela data),
-- presentes e justificados por nome, visitantes com a Loja de origem, ata anterior aprovada nesta sessão, expediente
-- lido, ordem do dia, trabalho apresentado no tempo de estudos e o total do Tronco (só o total, nunca quem deu).
-- O que só o Secretário sabe fica entre colchetes para ele completar: o uso da palavra, as deliberações e a hora do
-- encerramento. Usado pela Nova ata (já cria com o rascunho) e pelo botão "Preencher com o modelo".

create function public.ata_rascunho(p_ata uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  a public.atas;
  s public.sessoes;
  l public.lojas;
  v_meses text[] := array['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'];
  v_grau text;
  v_tipo text;
  v_cargo jsonb;
  v_pres text; v_npres int; v_just text; v_vis text; v_ant text; v_exp text; v_estudo text; v_tronco numeric;
  v_partes text[] := '{}';
begin
  select * into a from public.atas where id = p_ata;
  if a.id is null or not (public.tem_permissao(a.loja_id, 'secretaria.editar') or public.tem_permissao(a.loja_id, 'loja.config')) then
    raise exception 'Sem permissão';
  end if;
  select * into s from public.sessoes where id = a.sessao_id;
  select * into l from public.lojas where id = a.loja_id;
  if s.id is null then raise exception 'Ata sem sessão'; end if;

  v_grau := case s.grau when 1 then 'Aprendiz' when 2 then 'Companheiro' else 'Mestre' end;
  v_tipo := case s.tipo when 'ordinaria' then 'Sessão Ordinária' when 'magna' then 'Sessão Magna' || coalesce(' de ' || nullif(trim(s.finalidade), ''), '')
                        when 'estudos' then 'Sessão de Estudos' else 'Sessão' end;
  -- quem ocupava os cargos na data da sessão
  select jsonb_object_agg(c.codigo, i.nome) into v_cargo
  from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id join public.irmaos i on i.id = m.irmao_id
  where m.loja_id = a.loja_id and s.data between m.inicio and m.fim
    and c.codigo in ('veneravel', 'primeiro_vigilante', 'segundo_vigilante', 'secretario');

  select string_agg('Ir∴ ' || i.nome, ', ' order by i.nome), count(*) into v_pres, v_npres
  from public.presencas p join public.irmaos i on i.id = p.irmao_id where p.sessao_id = s.id and p.situacao = 'presente';
  select string_agg('Ir∴ ' || i.nome, ', ' order by i.nome) into v_just
  from public.presencas p join public.irmaos i on i.id = p.irmao_id where p.sessao_id = s.id and p.situacao = 'justificada';
  select string_agg('Ir∴ ' || v.nome
                    || coalesce(', ' || case v.grau when 1 then 'Aprendiz' when 2 then 'Companheiro' when 3 then 'Mestre' end, '')
                    || coalesce(', da ' || nullif(trim(v.loja_origem), '') || coalesce(' nº ' || nullif(trim(v.numero_loja), ''), ''), '')
                    || coalesce(', Oriente de ' || nullif(trim(v.oriente), ''), ''), '; ' order by v.nome) into v_vis
  from public.visitantes v where v.sessao_id = s.id;
  select string_agg(format('a ata nº %s, da sessão de %s', x.numero, to_char(coalesce(x.data_sessao, ss.data), 'DD/MM/YYYY')), '; ' order by ss.data) into v_ant
  from public.atas x left join public.sessoes ss on ss.id = x.sessao_id where x.aprovada_em_sessao_id = s.id;
  select string_agg(concat_ws(', ', nullif('nº ' || coalesce(nullif(trim(e.numero), ''), ''), 'nº '), nullif(trim(e.correspondente), ''), nullif(trim(e.assunto), '')), '; ' order by e.data) into v_exp
  from public.expediente e where e.lida_em_sessao_id = s.id;
  select string_agg(format('o Ir∴ %s apresentou o trabalho “%s”', i.nome, t.titulo), '; ') into v_estudo
  from public.trabalhos t join public.irmaos i on i.id = t.irmao_id where t.lido_em_sessao_id = s.id;
  select coalesce((select sum(c.valor) from public.tronco_contribuicoes c where c.tronco_sessao_id = ts.id and c.status = 'confirmada'), 0)
         + coalesce(ts.dinheiro, 0) into v_tronco
  from public.tronco_sessoes ts where ts.sessao_id = s.id;

  v_partes := v_partes || format('Aos %s dias do mês de %s de %s%s%s, reuniu-se a %s%s%s, em %s no Grau de %s, sob a presidência do Venerável Mestre %s%s.',
    extract(day from s.data)::int, v_meses[extract(month from s.data)::int], extract(year from s.data)::int,
    coalesce(', às ' || case when extract(minute from s.hora) = 0 then to_char(s.hora, 'FMHH24"h"') else to_char(s.hora, 'FMHH24"h"MI') end, ''),
    case when s.modalidade = 'online' then ', em reunião online' else coalesce(', em ' || nullif(trim(s.local), ''), '') end,
    trim(l.nome), coalesce(' nº ' || nullif(trim(l.numero::text), ''), ''), coalesce(', ao Oriente de ' || nullif(trim(l.cidade), ''), ''),
    v_tipo, v_grau,
    coalesce('Ir∴ ' || (v_cargo->>'veneravel'), '[nome]'),
    case when v_cargo ? 'primeiro_vigilante' or v_cargo ? 'segundo_vigilante'
         then format(', com os Vigilantes %s e %s', coalesce('Ir∴ ' || (v_cargo->>'primeiro_vigilante'), '[1º Vigilante]'),
                     coalesce('Ir∴ ' || (v_cargo->>'segundo_vigilante'), '[2º Vigilante]'))
         else '' end);
  v_partes := v_partes || case when v_npres > 0
    then format('Estiveram presentes %s obreiro%s do quadro: %s.', v_npres, case when v_npres = 1 then '' else 's' end, v_pres)
    else '[Presenças: a chamada desta sessão não foi registrada.]' end
    || coalesce(' Justificaram a ausência: ' || v_just || '.', '');
  if v_vis is not null then v_partes := v_partes || ('Visitantes: ' || v_vis || '.'); end if;
  v_partes := v_partes || coalesce('Foi lida e aprovada ' || v_ant || '.', '[Leitura e aprovação da ata anterior.]');
  v_partes := v_partes || coalesce('Expediente lido: ' || v_exp || '.', '[Expediente: registre aqui o que foi lido.]');
  if nullif(trim(s.pauta), '') is not null then v_partes := v_partes || ('Ordem do dia:' || E'\n' || trim(s.pauta)); end if;
  if v_estudo is not null then v_partes := v_partes || ('No tempo de estudos, ' || v_estudo || '.'); end if;
  if coalesce(v_tronco, 0) > 0 then
    v_partes := v_partes || ('O Tronco de Beneficência rendeu ' || private.moeda(v_tronco) || '.');
  else
    v_partes := v_partes || '[Tronco de Beneficência: valor arrecadado.]'::text;
  end if;
  v_partes := v_partes || '[Uso da palavra e deliberações: registre aqui.]'::text;
  v_partes := v_partes || format('Nada mais havendo a tratar, o Venerável Mestre encerrou a sessão às [hora], e eu, %s, Secretário, lavrei a presente ata nº %s, que vai assinada por mim e pelo Venerável Mestre.',
    coalesce('Ir∴ ' || (v_cargo->>'secretario'), '[nome]'), a.numero);
  return array_to_string(v_partes, E'\n\n');
end $$;
revoke execute on function public.ata_rascunho from public, anon;
grant execute on function public.ata_rascunho to authenticated;
