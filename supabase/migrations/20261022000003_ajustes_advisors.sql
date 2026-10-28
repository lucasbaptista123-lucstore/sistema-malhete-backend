-- Sistema Malhete — Fase 1: ajustes apontados pelos advisors do Supabase.

-- rls_auto_enable() é criada pelo Supabase em projeto novo (event trigger).
-- Ninguém precisa chamá-la pela API.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- auth.uid() dentro de select: avaliado uma vez por consulta, não por linha.
drop policy proprio_ou_cadastro_le on public.irmaos;
create policy proprio_ou_cadastro_le on public.irmaos for select to authenticated
  using (user_id = (select auth.uid()) or public.tem_permissao(loja_id, 'cadastro.ler'));
drop policy proprio_edita on public.irmaos;
create policy proprio_edita on public.irmaos for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Índices nas chaves estrangeiras.
create index on public.familiares (loja_id);
create index on public.gestoes (loja_id);
create index on public.loja_cargos (rito_cargo_id);
create index on public.lojas (criado_por);
create index on public.lojas (oriente_id);
create index on public.lojas (rito_id);
create index on public.mandatos (cargo_id);
create index on public.mandatos (gestao_id);
create index on public.mandatos (loja_id);
