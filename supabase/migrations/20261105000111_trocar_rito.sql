-- Trocar o rito da Loja (05/11, pedido do Lucas para testar os outros ritos no TESTE).
-- Só o Venerável (loja.config). Os cargos seguem o rito novo pelo CÓDIGO:
--   * código que existe no rito novo: o cargo continua (mesmos mandatos e permissões), muda nome, ordem
--     e grau acompanhado para os do rito novo;
--   * código que só existia no rito antigo: sem mandato é apagado; com mandato vira cargo extra da Loja
--     (o histórico fica), sem as permissões fixas;
--   * cargo do rito novo que a Loja não tinha: entra com as permissões padrão;
--   * cargos extras criados pelo Venerável não mudam.
-- Voltar ao rito anterior reaproveita os cargos que ficaram como extra (mesmo código).
-- A trava dos cargos, quando o próprio sistema mexe, devolvia NEW também no DELETE (NEW é nulo no DELETE),
-- o que cancelava a exclusão sem erro. Agora devolve OLD no DELETE.
create or replace function public.validar_loja_cargo() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_padrao text[];
  x text;
begin
  if current_setting('malhete.sistema', true) = 'on' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.rito_cargo_id is not null then raise exception 'Cargos do rito não podem ser apagados'; end if;
    if exists (select 1 from public.mandatos where cargo_id = old.id) then raise exception 'Este cargo já tem mandatos registrados'; end if;
    return old;
  end if;
  new.permissoes := coalesce((select array_agg(distinct p) from unnest(new.permissoes) p), '{}');
  foreach x in array new.permissoes loop
    if not (x = any (private.permissoes_fixas()) or x = any (private.permissoes_ajustaveis())) then
      raise exception 'Permissão desconhecida: %', x;
    end if;
  end loop;
  if new.rito_cargo_id is null then
    v_padrao := '{}';
  else
    select permissoes into v_padrao from public.rito_cargos where id = new.rito_cargo_id;
  end if;
  if tg_op = 'UPDATE' then
    if new.codigo is distinct from old.codigo or new.rito_cargo_id is distinct from old.rito_cargo_id or new.loja_id is distinct from old.loja_id then
      raise exception 'O cargo não pode trocar de código';
    end if;
    if new.grau_acompanhado is distinct from old.grau_acompanhado then raise exception 'O grau acompanhado segue o rito'; end if;
    v_padrao := old.permissoes;
  end if;
  if private.so_fixas(new.permissoes) <> private.so_fixas(coalesce(v_padrao, '{}')) then
    raise exception 'Movimentar Tesouraria e Tronco, editar Secretaria e Chancelaria, mudar graus e o acesso do Venerável são fixos do cargo (regra do GOB)';
  end if;
  return new;
end $$;

create or replace function public.trocar_rito(p_loja uuid, p_rito uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_antes uuid;
  v_mantidos int; v_novos int; v_apagados int; v_extras int;
begin
  if not public.tem_permissao(p_loja, 'loja.config') then raise exception 'Só o Venerável troca o rito'; end if;
  if not exists (select 1 from public.ritos where id = p_rito and ativo) then raise exception 'Rito ainda não disponível'; end if;
  select rito_id into v_antes from public.lojas where id = p_loja for update;
  if v_antes is not distinct from p_rito then
    return jsonb_build_object('mantidos', 0, 'novos', 0, 'apagados', 0, 'extras', 0);
  end if;

  perform set_config('malhete.sistema', 'on', true);

  update public.loja_cargos c
     set rito_cargo_id = r.id, nome = r.nome, ordem = r.ordem, grau_acompanhado = r.grau_acompanhado
    from public.rito_cargos r
   where c.loja_id = p_loja and r.rito_id = p_rito and r.codigo = c.codigo;
  get diagnostics v_mantidos = row_count;

  insert into public.loja_cargos (loja_id, rito_cargo_id, codigo, nome, ordem, grau_acompanhado, permissoes)
  select p_loja, r.id, r.codigo, r.nome, r.ordem, r.grau_acompanhado, r.permissoes
    from public.rito_cargos r
   where r.rito_id = p_rito
     and not exists (select 1 from public.loja_cargos c where c.loja_id = p_loja and c.codigo = r.codigo);
  get diagnostics v_novos = row_count;

  -- sobrou do rito antigo
  delete from public.loja_cargos c
   where c.loja_id = p_loja and c.rito_cargo_id is not null
     and c.rito_cargo_id not in (select id from public.rito_cargos where rito_id = p_rito)
     and not exists (select 1 from public.mandatos m where m.cargo_id = c.id);
  get diagnostics v_apagados = row_count;

  update public.loja_cargos c
     set rito_cargo_id = null,
         permissoes = coalesce((select array_agg(x) from unnest(c.permissoes) x where not x = any (private.permissoes_fixas())), '{}')
   where c.loja_id = p_loja and c.rito_cargo_id is not null
     and c.rito_cargo_id not in (select id from public.rito_cargos where rito_id = p_rito);
  get diagnostics v_extras = row_count;

  update public.lojas set rito_id = p_rito where id = p_loja;

  perform set_config('malhete.sistema', 'off', true);

  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois)
  values (p_loja, 'lojas', p_loja, 'trocar_rito',
          jsonb_build_object('rito', (select sigla from public.ritos where id = v_antes)),
          jsonb_build_object('rito', (select sigla from public.ritos where id = p_rito),
                             'mantidos', v_mantidos, 'novos', v_novos, 'apagados', v_apagados, 'extras', v_extras));

  return jsonb_build_object('mantidos', v_mantidos, 'novos', v_novos, 'apagados', v_apagados, 'extras', v_extras);
end $$;
revoke execute on function public.trocar_rito from public, anon;
grant execute on function public.trocar_rito to authenticated;
