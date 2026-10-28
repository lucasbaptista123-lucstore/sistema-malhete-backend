Agora implemente a **Tesouraria** e **Minhas mensalidades**. Continue usando só o Supabase existente (sem criar tabelas, migrations ou SQL). Respeite `usePermissao`.

## Regras do banco que a tela precisa refletir

- Contas têm `tipo`: `caixa`, `banco` ou `tronco`. Caixa/banco usam `tesouraria.*`; a conta do tronco usa `tronco.*` (o Hospitaleiro só vê e lança no tronco). O RLS já filtra: liste o que vier.
- **Lançamento nunca é editado nem apagado.** Não mostre botões de editar/excluir. A correção é o **Estornar**, que pede o motivo.
- Mensalidade é escrita só pelas funções (`gerar_mensalidades`, `registrar_pagamento`, `cancelar_mensalidade`) — nunca insert/update direto.

## Tabelas e views

- `contas_saldo` (view): `conta_id, loja_id, nome, tipo, ativa, saldo`
- `contas_financeiras`: `id, loja_id, nome, tipo, saldo_inicial, ativa`
- `categorias_financeiras`: `id, loja_id, codigo, nome, tipo ('receita'|'despesa'), ativa`
- `lancamentos`: `id, loja_id, conta_id, conta_destino_id, categoria_id, tipo ('receita'|'despesa'|'transferencia'), valor, data, descricao, irmao_id, documento, estorno_de, motivo_estorno, criado_por, criado_em`
- `mensalidades`: `id, loja_id, irmao_id, competencia (1º dia do mês), valor, vencimento, status ('aberta'|'paga'|'cancelada'), lancamento_id, motivo_cancelamento`
- `inadimplencia` (view): `loja_id, irmao_id, nome, mensalidades_atrasadas, total_atrasado, vencimento_mais_antigo`

## Funções (rpc)

- `estornar_lancamento({ p_lancamento, p_motivo })` → uuid
- `gerar_mensalidades({ p_loja, p_competencia, p_valor, p_vencimento })` → int (quantas criou; irmãos ativos que ainda não tinham a do mês)
- `registrar_pagamento({ p_mensalidade, p_conta, p_data?, p_valor? })` → uuid do lançamento (não aceita conta do tronco)
- `cancelar_mensalidade({ p_mensalidade, p_motivo })`

## Tesouraria (abas)

**1. Visão geral**
- Cartões com o saldo de cada conta ativa (`contas_saldo`) e o total.
- Resumo do mês: receitas, despesas e resultado (some `lancamentos` do mês por tipo, ignorando transferências).
- Cartão de inadimplência: quantidade de irmãos e total em atraso (link para a aba Mensalidades).

**2. Lançamentos** (`tesouraria.ler` ou `tronco.ler`)
- Lista por período (padrão: mês atual), filtros por conta, categoria e tipo. Valores de receita em verde, despesa em vermelho, transferência neutra mostrando "Conta A → Conta B". Estornos (valor negativo, `estorno_de` preenchido) aparecem riscados/marcados como "Estorno", e o lançamento original ganha o selo "Estornado".
- Botão **Novo lançamento** (se pode lançar na conta): tipo (Receita/Despesa/Transferência), conta (e conta destino na transferência), categoria filtrada pelo tipo e só as `ativa`, valor, data, descrição, irmão (opcional, do diretório), documento (opcional).
- Em cada lançamento não estornado e que não é estorno: ação **Estornar** com modal pedindo o motivo.
- Exportar CSV do período.

**3. Mensalidades** (`tesouraria.ler`)
- Seletor de competência (mês/ano). Tabela: irmão, valor, vencimento, status (aberta / paga / cancelada / **atrasada** quando aberta e vencida).
- Com `tesouraria.editar`:
  - **Gerar mensalidades do mês**: modal com competência, valor e vencimento → mostra "N mensalidades geradas".
  - **Dar baixa** numa aberta: conta (só caixa/banco), data (hoje), valor (padrão = valor da mensalidade).
  - **Cancelar** uma aberta: pede motivo.
  - Mensalidade paga: link para o lançamento; para desfazer, estorne o lançamento (a mensalidade volta a "aberta" sozinha) — explique isso num tooltip.
- Sub-aba **Inadimplentes**: view `inadimplencia`, ordenada pelo total, com botão para copiar uma mensagem cordial de lembrete (sem termos maçônicos).

**4. Contas e categorias** (`tesouraria.editar`)
- Contas: criar, renomear, ajustar saldo inicial, desativar (não existe excluir).
- Categorias: lista agrupada por Receita/Despesa. Criar nova (nome + tipo), renomear, ativar/desativar. **Tipo não é editável** depois de criada. Categorias com `codigo` aparecem com selo "padrão"; a de código `mensalidades` não pode ser desativada (desabilite o switch com tooltip).

## Minhas mensalidades (todo irmão)

Lista das próprias mensalidades (`mensalidades` — o RLS já mostra só as dele): competência, valor, vencimento, status, com destaque para as atrasadas e o total em aberto no topo.
