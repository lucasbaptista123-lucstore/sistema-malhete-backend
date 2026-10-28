-- Sistema Malhete — PERMISSÕES AJUSTÁVEIS por loja (Venerável/loja.config).
-- A loja ajusta quem VÊ cada área e as funções de apoio (convocar, mural, biblioteca, hospitalaria, comunicados,
-- editar cadastro) e cria cargos extras. FIXAS (regra do GOB, travadas no banco): movimentar Tesouraria/Tronco,
-- editar Secretaria/Chancelaria, mudar graus, avaliar trabalhos (pelo grau acompanhado), loja.config e o '*'
-- do Venerável — só seguem o padrão do rito.

create function private.permissoes_fixas() returns text[]
language sql immutable set search_path = '' as $$
  select public.permissoes_exclusivas() || array['graus.editar', 'trabalhos.avaliar', 'loja.config', '*']
$$;
create function private.permissoes_ajustaveis() returns text[]
language sql immutable set search_path = '' as $$
  select array['cadastro.ler', 'cadastro.editar', 'tesouraria.ler', 'tronco.ler', 'secretaria.ler', 'chancelaria.ler',
               'auditoria.ler', 'sessoes.convocar', 'mural.publicar', 'biblioteca.editar', 'hospitalaria.editar',
               'comunicacao.enviar', 'cargos.editar']
$$;
create function private.so_fixas(p text[]) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(x order by x), '{}') from unnest(p) x where x = any (private.permissoes_fixas())
$$;

create function public.validar_loja_cargo() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_padrao text[];
  x text;
begin
  if current_setting('malhete.sistema', true) = 'on' then return new; end if;
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
create trigger validar before insert or update or delete on public.loja_cargos
for each row execute function public.validar_loja_cargo();
revoke execute on function public.validar_loja_cargo from public, anon, authenticated;

-- volta tudo ao padrão do rito (cargos extras ficam, sem mudança)
create function public.restaurar_permissoes(p_loja uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.tem_permissao(p_loja, 'loja.config') then raise exception 'Só o Venerável ajusta permissões'; end if;
  perform set_config('malhete.sistema', 'on', true);
  update public.loja_cargos c set permissoes = r.permissoes
  from public.rito_cargos r where r.id = c.rito_cargo_id and c.loja_id = p_loja
    and (select array_agg(x order by x) from unnest(c.permissoes) x) is distinct from (select array_agg(x order by x) from unnest(r.permissoes) x);
  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $$;
revoke execute on function public.restaurar_permissoes from public, anon;
grant execute on function public.restaurar_permissoes to authenticated;
revoke execute on function private.permissoes_fixas, private.permissoes_ajustaveis, private.so_fixas from public, anon;
