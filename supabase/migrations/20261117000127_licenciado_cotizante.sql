-- Sistema Malhete: LICENCIADO COTIZANTE (17/11, pergunta do Lucas: "irmão cotizante que está licenciado e não pode ir
-- na sessão"). Licenciado já fica fora de convocação, lembrete do dia, pedido de justificativa e frequência (só
-- 'ativo'), e já recebe cobrança, régua e aviso, e mantém o acesso. Faltava a mensalidade: gerar_mensalidades e
-- adiantar_mensalidades só olhavam 'ativo', então o licenciado parava de ter mensalidade. Agora entram ativos e
-- licenciados; quem não é cotizante a Tesouraria desmarca no "Gerar mensalidades" (o diálogo mostra "licenciado").

CREATE OR REPLACE FUNCTION public.gerar_mensalidades(p_loja uuid, p_competencia date, p_valor numeric, p_vencimento date, p_irmaos uuid[] DEFAULT NULL::uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_comp date := date_trunc('month', p_competencia)::date;
  n int;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para gerar mensalidades';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor da mensalidade';
  end if;

  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
  select p_loja, 'receber', 'Mensalidade ' || to_char(v_comp, 'MM/YYYY'),
         (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'mensalidades'),
         i.id, p_valor, p_vencimento, v_comp, 'mensalidade'
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
    and (case when p_irmaos is null
              then not exists (select 1 from public.mensalidade_isentos x where x.irmao_id = i.id)
              else i.id = any (p_irmaos) end)
  on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;

  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.adiantar_mensalidades(p_loja uuid, p_meses integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_irmao uuid := public.meu_irmao_id(p_loja);
  c public.tesouraria_config;
  v_valor numeric;
  v_cat uuid;
  v_inicio date;
  n int;
begin
  if v_irmao is null or not exists (select 1 from public.irmaos where id = v_irmao and situacao in ('ativo', 'licenciado')) then
    raise exception 'Só irmãos ativos ou licenciados adiantam mensalidades';
  end if;
  if p_meses is null or p_meses < 1 or p_meses > 12 then raise exception 'Escolha de 1 a 12 meses'; end if;
  select * into c from public.tesouraria_config where loja_id = p_loja;
  v_valor := coalesce(c.valor_mensalidade,
    (select valor from public.titulos where loja_id = p_loja and origem = 'mensalidade' order by competencia desc limit 1));
  if v_valor is null then raise exception 'A Tesouraria ainda não definiu o valor da mensalidade'; end if;
  select id into v_cat from public.categorias_financeiras where loja_id = p_loja and codigo = 'mensalidades';
  -- começa no mês seguinte à última mensalidade dele (ou no mês atual, se não tiver nenhuma)
  v_inicio := coalesce(
    (select max(competencia) + interval '1 month' from public.titulos where irmao_id = v_irmao and origem = 'mensalidade' and not cancelado),
    date_trunc('month', current_date))::date;
  v_inicio := greatest(v_inicio, date_trunc('month', current_date)::date);
  perform set_config('malhete.sistema', 'on', true);
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
  select p_loja, 'receber', 'Mensalidade ' || to_char(m, 'MM/YYYY'), v_cat, v_irmao, v_valor,
         greatest(make_date(extract(year from m)::int, extract(month from m)::int, coalesce(c.dia_vencimento, 10)), current_date), m::date, 'mensalidade'
  from generate_series(v_inicio, v_inicio + make_interval(months => p_meses - 1), interval '1 month') m
  on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;
  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $function$;
