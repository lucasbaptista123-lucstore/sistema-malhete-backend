# Sistema Malhete

ERP SaaS multi-tenant para lojas maçônicas. Projeto pessoal da dona (tesoureira de uma loja) — a loja dela é só cliente piloto, sem privilégio.

## Escopo
- Potência: GOB (GOB → Grande Oriente Estadual → Loja). Ritos são modelos configuráveis; só REAA ativo por enquanto.
- Graus simbólicos 1–3 + Mestre Instalado. Graus filosóficos fora do escopo.
- Módulos: cadastros, tesouraria, secretaria, chancelaria, vigilância (trabalhos + biblioteca por grau), portal do irmão, WhatsApp.

## Stack
- Supabase projeto `heblivnebprikxcjsuan` (org própria, separada da Lucstore). Migrations em `supabase/migrations/`, teste de permissões em `supabase/tests/`.
- Frontend no Lovable, sincronizado com GitHub.
- n8n para rotinas (cobrança, lembretes).
- Asaas: cada loja conecta a PRÓPRIA chave; a conta Asaas da plataforma só cobra a assinatura das lojas. Nunca misturar.
- WhatsApp: MVP via Evolution API (QR por loja), atrás de uma camada que permita trocar pela Meta Cloud API depois.

## Regras de segurança
- Toda tabela de dados tem `loja_id` + RLS. Acesso vem de `tem_permissao(loja, 'modulo.acao')`, derivado do mandato vigente (ou `admin_loja`). `*` = Venerável.
- Conteúdo restrito por grau tem `grau_minimo`; irmão vê o próprio grau e os abaixo (`pode_ver_grau`).
- Lançamento financeiro nunca é apagado, só estornado. Tudo com `audit_log`.
- Pertencer à maçonaria é dado sensível (LGPD art. 5º II): mensagens e remetentes discretos, admin da plataforma sem acesso a dados de loja por padrão.

## Fases
0 desenho ✅ · 1 fundação (migrations prontas, aplicar e testar) · 2 tesouraria MVP · 3 chancelaria · 4 portal + vigilância · 5 secretaria · 6 DRE/conciliação · 7 cobrança SaaS + Meta Tech Provider
