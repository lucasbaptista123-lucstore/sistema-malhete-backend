-- Sistema Malhete: notificações no celular (Web Push). Cada aparelho inscrito guarda endpoint + chaves.
-- O envio sai junto com a fila de notificações (mesma pausa dos envios automáticos) e por teste manual.
create table public.push_inscricoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  aparelho text,
  criado_em timestamptz not null default now()
);
create index on public.push_inscricoes (user_id);
alter table public.push_inscricoes enable row level security;
create policy proprio on public.push_inscricoes for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
