Crie o app **Sistema Malhete**: um sistema de gestão para lojas maçônicas (GOB, rito REAA). Interface em português do Brasil, sóbria e profissional: azul-marinho profundo, dourado discreto para destaques, fundo claro, tipografia serifada nos títulos e sem serifa no corpo. Desktop e celular.

## Backend (já existe — NÃO crie tabelas, migrations nem edge functions)

Use o Supabase que já está pronto, só com o cliente `@supabase/supabase-js`:

- URL: `https://heblivnebprikxcjsuan.supabase.co`
- Publishable key: `sb_publishable_Ge7-D-NsdDZgZCHirtTpeA_lfAs0um8`

Não conecte a integração nativa de Supabase do Lovable e não gere SQL. Toda a segurança (quem vê o quê) já está no banco via RLS; o app só lê, grava e chama as funções abaixo. Quando uma operação falhar, mostre a mensagem de erro do Postgres num toast (elas já vêm em português).

## Login

- E-mail + senha (cadastro, login, "esqueci a senha"), com `emailRedirectTo: window.location.origin`.
- Depois do login, chame `rpc('minhas_lojas')` (retorna lista de `uuid`).
  - Nenhuma loja → tela **"Cadastrar minha loja"**.
  - Uma loja → entra direto nela.
  - Mais de uma → seletor de loja (guarde a escolhida no localStorage e mostre a loja atual no topo, com opção de trocar).

## Cadastrar minha loja (onboarding)

Formulário que chama:

```
rpc('criar_loja', {
  p_nome, p_numero, p_oriente_id, p_rito_id, p_cidade, p_uf, p_meu_nome, p_meu_grau
}) -> uuid da loja
```

- `p_oriente_id`: select de `orientes` (colunas `id, uf, nome`), rótulo pela UF.
- `p_rito_id`: select de `ritos` (`id, sigla, nome, ativo`); só os `ativo = true` habilitados, os outros aparecem desabilitados com "em breve".
- `p_meu_grau`: 1 Aprendiz, 2 Companheiro, 3 Mestre (padrão 3).

## Permissões e menu

Ao entrar numa loja, chame `rpc('minhas_permissoes', { p_loja })` → `text[]`. Uma permissão `x.ler` é satisfeita por `x.ler`, `x.editar` ou `*`; `x.editar` por `x.editar` ou `*`. Crie um hook `usePermissao('tesouraria.editar')`.

Menu lateral (esconda o que o usuário não pode ver):
- **Início** — todos
- **Irmãos** — todos (diretório); ficha completa só com `cadastro.ler`
- **Gestão e cargos** — todos veem; edita com `cargos.editar`
- **Tesouraria** — `tesouraria.ler` ou `tronco.ler` (a tela vem no próximo passo; por ora deixe a página com "em construção")
- **Minhas mensalidades** — todos (próximo passo; deixe "em construção")
- **Configurações da loja** — `loja.config`
- **Auditoria** — `auditoria.ler`

## Início

Cartão com nome/número da loja (`lojas`: `id, nome, numero, cidade, uf`), grau do usuário (`rpc('meu_grau', { p_loja })`), e os cargos vigentes da gestão atual.

## Irmãos

- Lista: `rpc('diretorio', { p_loja })` → `id, nome, grau, mestre_instalado, situacao`. Busca por nome, filtro por grau e situação. Grau como selo: 1 Aprendiz, 2 Companheiro, 3 Mestre (+ "M∴I∴" se `mestre_instalado`).
- Com `cadastro.ler`: ao clicar abre a ficha completa da tabela `irmaos`:
  `nome, cpf, cim, email, telefone, data_nascimento, grau, mestre_instalado, data_iniciacao, data_elevacao, data_exaltacao, situacao, endereco (jsonb: logradouro, numero, bairro, cidade, uf, cep), observacoes`
  e os familiares (`familiares`: `id, irmao_id, loja_id, nome, parentesco, data_nascimento, telefone`).
- Com `cadastro.editar`: botões **Novo irmão** e **Editar** (insert/update em `irmaos` com `loja_id`), e CRUD de familiares. `situacao` é enum: `ativo, irregular, licenciado, quite_placet, falecido, desligado`.
- **Meu cadastro** (todo usuário, no menu do avatar): edita os próprios `telefone, email, endereco, data_nascimento` e familiares. Os demais campos aparecem só para leitura (o banco bloqueia).
- Para convidar um irmão a usar o app: por enquanto, mostre na ficha o texto "Peça ao irmão para criar a conta com o e-mail X" — o vínculo `user_id` será feito depois.

## Gestão e cargos

- `gestoes` (`id, loja_id, nome, inicio, fim`) — lista; com `cargos.editar`, criar/editar.
- Na gestão selecionada: tabela de cargos (`loja_cargos`: `id, codigo, nome, ordem`, ordenado por `ordem`) com quem ocupa cada um (`mandatos`: `id, loja_id, gestao_id, irmao_id, cargo_id, inicio, fim`). Com `cargos.editar`: escolher o irmão de cada cargo (select do diretório), com início/fim preenchidos pelas datas da gestão.

## Configurações da loja (`loja.config`)

Editar `nome, numero, cidade, uf, cnpj` em `lojas`.

## Auditoria (`auditoria.ler`)

Tabela de `audit_log` (`em, tabela, acao, user_id, antes, depois`) filtrada por `loja_id`, mais recente primeiro, paginada; ao abrir uma linha, mostre o diff entre `antes` e `depois`.

## Regras gerais

- Sempre filtre por `loja_id` da loja atual nas consultas e envie `loja_id` nos inserts.
- Datas em dd/mm/aaaa, dinheiro em R$ 1.234,56.
- Nada de dados de exemplo inventados: telas vazias mostram um estado vazio com a ação principal.
- Discrição: o nome do app e os textos não devem expor termos maçônicos em títulos de aba/notificações além de "Sistema Malhete".
