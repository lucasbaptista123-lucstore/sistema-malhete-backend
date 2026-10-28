-- Sistema Malhete: aceite dos Termos de Uso e da Política de Privacidade (por usuário e versão).
-- O app pede o aceite no primeiro acesso e sempre que a versão mudar.
create table public.aceites_termos (
  user_id uuid not null references auth.users(id) on delete cascade,
  versao text not null,
  aceito_em timestamptz not null default now(),
  primary key (user_id, versao)
);
alter table public.aceites_termos enable row level security;
create policy le_proprio on public.aceites_termos for select to authenticated using (user_id = (select auth.uid()));
create policy aceita on public.aceites_termos for insert to authenticated with check (user_id = (select auth.uid()));
