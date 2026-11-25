-- Sistema Malhete: MENSALIDADES GERADAS SOZINHAS, SE A TESOURARIA LIGAR (25/11, pedido do Lucas: "a tesouraria pode
-- configurar"). Gerar o ano todo de uma vez já existia no diálogo "Gerar mensalidades" (De/Até, "Ano todo").
-- tesouraria_config.mensalidade_auto:
--   'desligada' (padrão): como hoje, só pelo diálogo;
--   'mensal': 15 dias antes de cada mês, gera a mensalidade do mês seguinte;
--   'anual': em dezembro, gera as doze mensalidades do ano seguinte.
-- Quem entra: quem teve mensalidade no mês anterior ao primeiro mês gerado (o diálogo continua sendo o único lugar de
-- marcar e desmarcar; quem foi desmarcado lá fica de fora) e o irmão novo: ativo ou licenciado, sem nenhuma
-- mensalidade, cadastrado DEPOIS da última mensalidade gerada no mês anterior (quem já existia e foi desmarcado não
-- conta como novo). Loja que nunca gerou nenhuma: todos os ativos e licenciados. Valor e dia de vencimento vêm de "Como os irmãos pagam". Mensalidade que já existe, mesmo excluída,
-- não é refeita. O irmão é avisado perto de cada vencimento, como sempre (aviso_cobranca só avisa a 20 dias).

alter table public.tesouraria_config
  add column mensalidade_auto text not null default 'desligada' check (mensalidade_auto in ('desligada', 'mensal', 'anual'));

create function private.gerar_mensalidades_auto(p_hoje date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_hoje date := coalesce(p_hoje, private.hoje_sp());
  v_prox date := (date_trunc('month', v_hoje) + interval '1 month')::date;
  cfg record;
  v_meses date[];
  v_base date;
  v_ultima timestamptz;
  m date;
  k int;
  n int := 0;
begin
  for cfg in
    select c.loja_id, c.mensalidade_auto, c.valor_mensalidade, coalesce(c.dia_vencimento, 10) as dia
    from public.tesouraria_config c
    where c.mensalidade_auto <> 'desligada' and coalesce(c.valor_mensalidade, 0) > 0
  loop
    v_meses := null;
    if cfg.mensalidade_auto = 'mensal' and v_hoje >= v_prox - 15 then
      v_meses := array[v_prox];
    elsif cfg.mensalidade_auto = 'anual' and extract(month from v_hoje) = 12 then
      select array_agg((v_prox + make_interval(months => g))::date order by g) into v_meses from generate_series(0, 11) g;
    end if;
    continue when v_meses is null;
    v_base := (v_meses[1] - interval '1 month')::date;
    select max(t.criado_em) into v_ultima from public.titulos t
    where t.loja_id = cfg.loja_id and t.origem = 'mensalidade' and t.competencia = v_base;
    foreach m in array v_meses loop
      insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
      select cfg.loja_id, 'receber', 'Mensalidade ' || to_char(m, 'MM/YYYY'),
             (select id from public.categorias_financeiras where loja_id = cfg.loja_id and codigo = 'mensalidades'),
             i.id, cfg.valor_mensalidade,
             make_date(extract(year from m)::int, extract(month from m)::int,
                       least(cfg.dia, extract(day from (m + interval '1 month - 1 day'))::int)),
             m, 'mensalidade'
      from public.irmaos i
      where i.loja_id = cfg.loja_id and i.situacao in ('ativo', 'licenciado')
        and (exists (select 1 from public.titulos t where t.irmao_id = i.id and t.origem = 'mensalidade'
                     and t.competencia = v_base and not t.cancelado)
             or (not exists (select 1 from public.titulos t where t.irmao_id = i.id and t.origem = 'mensalidade')
                 and (v_ultima is null or i.criado_em > v_ultima)))
      on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;
      get diagnostics k = row_count;
      n := n + k;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function private.gerar_mensalidades_auto from public, anon, authenticated;

-- todo dia às 8h de Brasília (11h UTC), antes dos lembretes; não faz nada nas Lojas que não ligaram
select cron.schedule('malhete-mensalidades-auto', '0 11 * * *', $c$ select private.gerar_mensalidades_auto() $c$);
