// Código comum das edge functions do Asaas (Sistema Malhete).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BASE: Record<string, string> = {
  producao: "https://api.asaas.com/v3",
  sandbox: "https://api-sandbox.asaas.com/v3",
};

export const EVENTOS_COBRANCA = [
  "PAYMENT_CREATED", "PAYMENT_UPDATED", "PAYMENT_CONFIRMED", "PAYMENT_RECEIVED", "PAYMENT_OVERDUE",
  "PAYMENT_DELETED", "PAYMENT_RESTORED", "PAYMENT_REFUNDED", "PAYMENT_PARTIALLY_REFUNDED", "PAYMENT_RECEIVED_IN_CASH_UNDONE",
];
// saídas feitas pelo Tesoureiro no Asaas (PIX/TED enviados e contas pagas): o aviso dispara a leitura do extrato na hora
export const EVENTOS_SAIDA = [
  "TRANSFER_CREATED", "TRANSFER_DONE", "TRANSFER_FAILED", "TRANSFER_CANCELLED",
  "BILL_PAID", "BILL_FAILED", "BILL_CANCELLED", "BILL_REFUNDED",
];
export const EVENTOS_WEBHOOK = [...EVENTOS_COBRANCA, ...EVENTOS_SAIDA];

/** Webhook já cadastrado sem os avisos de saída (lojas conectadas antes): acrescenta. */
export async function garantirEventosWebhook(loja: string, c: Credencial) {
  const { data: i } = await admin.from("integracoes_asaas").select("webhook_id").eq("loja_id", loja).maybeSingle();
  if (!i?.webhook_id) return "sem webhook";
  const wh = await asaas(c, `/webhooks/${i.webhook_id}`);
  const atuais = new Set<string>((wh.events ?? []) as string[]);
  if (EVENTOS_WEBHOOK.every((e) => atuais.has(e))) return "ok";
  await asaas(c, `/webhooks/${i.webhook_id}`, { method: "PUT", body: { events: EVENTOS_WEBHOOK } });
  return "atualizado";
}

export const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
export const CHAVE_PUBLICA =
  JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}")["default"] ?? Deno.env.get("SUPABASE_ANON_KEY")!;
const CHAVE_SECRETA =
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"] ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export const admin = createClient(SUPABASE_URL, CHAVE_SECRETA, { auth: { persistSession: false } });

export class Falha extends Error {
  constructor(msg: string, public status = 400) { super(msg); }
}

export const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

export type Credencial = { chave: string; ambiente: string; conta_id: string; ultima_sincronizacao: string | null };

export async function credencial(loja: string): Promise<Credencial> {
  const { data, error } = await admin.rpc("asaas_credenciais", { p_loja: loja });
  if (error) throw new Falha("Não foi possível ler a integração.", 500);
  const c = (data ?? [])[0];
  if (!c) throw new Falha("O Asaas não está conectado nesta loja.");
  return c as Credencial;
}

/** Chamada à API do Asaas com a chave da loja. */
export async function asaas(c: { ambiente: string; chave: string }, caminho: string, init: { method?: string; body?: unknown } = {}) {
  const r = await fetch(`${BASE[c.ambiente]}${caminho}`, {
    method: init.method ?? "GET",
    headers: { access_token: c.chave, "User-Agent": "SistemaMalhete", "Content-Type": "application/json" },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const texto = await r.text();
  const json = texto ? (() => { try { return JSON.parse(texto); } catch { return null; } })() : null;
  if (r.status === 401) throw new Falha("O Asaas recusou a chave. Confira se copiou a chave inteira (começa com $aact_).", 401);
  if (!r.ok) {
    const det = json?.errors?.[0]?.description;
    throw new Falha(det ? `Asaas: ${det}` : `O Asaas respondeu com erro (${r.status}).`, r.status >= 500 ? 502 : 400);
  }
  return json;
}

/** Percorre uma listagem paginada do Asaas. */
export async function listar(c: Credencial, caminho: string, params: Record<string, string>, max = 3000) {
  const out: Record<string, unknown>[] = [];
  for (let offset = 0; offset < max; offset += 100) {
    const q = new URLSearchParams({ ...params, offset: String(offset), limit: "100" });
    const pg = await asaas(c, `${caminho}?${q}`);
    out.push(...(pg?.data ?? []));
    if (!pg?.hasMore) break;
  }
  return out;
}

const isoDia = (d: Date) => d.toISOString().slice(0, 10);

/** Espelha um pagamento (busca o cliente no Asaas só se a cobrança ainda não existe aqui). */
export async function espelhar(loja: string, c: Credencial, evento: string, pg: Record<string, unknown>, clientes = new Map<string, unknown>()) {
  let cliente: unknown = null;
  const { data: existe } = await admin.from("titulos").select("id").eq("loja_id", loja).eq("asaas_id", String(pg.id)).maybeSingle();
  if (!existe && typeof pg.customer === "string") {
    cliente = clientes.get(pg.customer) ?? await asaas(c, `/customers/${pg.customer}`).catch(() => null);
    clientes.set(pg.customer, cliente);
  }
  const { data, error } = await admin.rpc("asaas_espelhar_pagamento", { p_loja: loja, p_evento: evento, p_pg: pg, p_cliente: cliente });
  if (error) throw new Error(error.message);
  return String(data);
}

/** Cria no Asaas as cobranças das contas a receber de irmãos que ainda não estão lá. */
export async function enviarCobrancas(loja: string, c: Credencial, soIrmao?: string) {
  const { data: pend, error } = await admin.rpc("asaas_cobrancas_pendentes", { p_loja: loja });
  if (error) throw new Error(error.message);
  let enviadas = 0, semCpf = 0, erros = 0;
  const hoje = isoDia(new Date());
  // multa (%) e juros (% ao mês) definidos pela Tesouraria vão na cobrança; o Asaas calcula no atraso
  const { data: enc } = await admin.rpc("asaas_encargos", { p_loja: loja });
  const multa = Number(enc?.[0]?.multa ?? 0), juros = Number(enc?.[0]?.juros ?? 0);
  const encargos = { ...(multa > 0 ? { fine: { value: multa, type: "PERCENTAGE" } } : {}), ...(juros > 0 ? { interest: { value: juros } } : {}) };
  for (const t of (pend ?? []) as Record<string, string | number | null>[]) {
    if (soIrmao && t.irmao_id !== soIrmao) continue;
    const cpf = String(t.cpf ?? "").replace(/\D/g, "");
    if (cpf.length !== 11 && cpf.length !== 14) { semCpf++; continue; }
    try {
      let cliente = t.asaas_cliente_id as string | null;
      if (!cliente) {
        const achados = await asaas(c, `/customers?cpfCnpj=${cpf}`);
        cliente = achados?.data?.[0]?.id ?? null;
        if (!cliente) {
          const novo = await asaas(c, "/customers", { method: "POST", body: {
            name: t.nome, cpfCnpj: cpf, email: t.email ?? undefined, mobilePhone: String(t.telefone ?? "").replace(/\D/g, "") || undefined,
            externalReference: t.irmao_id,
          } });
          cliente = novo.id;
        }
      }
      // não duplica se a cobrança já foi criada antes (ex.: queda no meio do envio)
      const ja = await asaas(c, `/payments?externalReference=${t.titulo_id}`);
      const pg = ja?.data?.find((p: Record<string, unknown>) => !p.deleted) ?? await asaas(c, "/payments", { method: "POST", body: {
        customer: cliente, billingType: "UNDEFINED", value: Number(t.valor),
        dueDate: String(t.vencimento) < hoje ? hoje : t.vencimento, description: t.descricao, externalReference: t.titulo_id,
        ...encargos,
      } });
      const { error: e } = await admin.rpc("asaas_vincular", { p_loja: loja, p_titulo: t.titulo_id, p_irmao: t.irmao_id, p_cliente_id: cliente, p_pg: pg });
      if (e) throw new Error(e.message);
      enviadas++;
    } catch (e) {
      erros++;
      console.error("enviar cobrança", t.titulo_id, e);
    }
  }
  return { enviadas, sem_cpf: semCpf, erros };
}

/** Extrato + varredura das cobranças (garante o espelho mesmo se algum aviso se perdeu) + envio de cobranças. */
export async function sincronizarLoja(loja: string, de?: string, ate?: string, soExtrato = false) {
  const c = await credencial(loja);
  const hoje = new Date();
  const inicio = c.ultima_sincronizacao
    ? new Date(new Date(c.ultima_sincronizacao).getTime() - 5 * 864e5)
    : new Date(hoje.getTime() - 90 * 864e5);
  de = de && /^\d{4}-\d{2}-\d{2}$/.test(de) ? de : isoDia(inicio);
  ate = ate && /^\d{4}-\d{2}-\d{2}$/.test(ate) ? ate : isoDia(hoje);

  // 1) cobranças criadas ou pagas no período
  const clientes = new Map<string, unknown>();
  const vistos = new Set<string>();
  let espelhadas = 0;
  const filtros: Record<string, string>[] = [{ "dateCreated[ge]": de, "dateCreated[le]": ate }, { "paymentDate[ge]": de, "paymentDate[le]": ate }];
  for (const filtro of filtros) {
    for (const pg of await listar(c, "/payments", filtro)) {
      if (vistos.has(String(pg.id))) continue;
      vistos.add(String(pg.id));
      await espelhar(loja, c, pg.deleted ? "PAYMENT_DELETED" : "VARREDURA", pg, clientes);
      espelhadas++;
    }
  }

  // 2) extrato
  const transacoes = await listar(c, "/financialTransactions", { startDate: de, finishDate: ate, order: "asc" }, 5000);
  const itens = transacoes
    .filter((t) => Number(t.value) !== 0)
    .map((t) => ({
      id_externo: t.id, data: t.date, valor: Number(t.value), descricao: (t.description as string) ?? t.type,
      tipo: t.type, referencia: t.paymentId ?? t.transferId ?? null,
    }));
  const ultima = transacoes[transacoes.length - 1];
  const { data: ext, error } = await admin.rpc("asaas_importar_extrato", {
    p_loja: loja, p_itens: itens, p_arquivo: `Asaas ${de} a ${ate}`,
    p_saldo: ultima ? Number(ultima.balance) : null, p_saldo_em: ultima ? ultima.date : null,
  });
  if (error) throw new Error(error.message);

  // 2b) toda saída (e entrada avulsa) do extrato vira lançamento; na 1ª vez, saldo inicial = saldo real do Asaas
  const { data: fim, error: eFim } = await admin.rpc("asaas_concluir_sincronizacao", {
    p_loja: loja, p_saldo: ultima ? Number(ultima.balance) : null, p_primeira: !c.ultima_sincronizacao,
  });
  if (eFim) throw new Error(eFim.message);

  // 3) mensalidades daqui que ainda não viraram cobrança lá (não quando é só o aviso de uma saída)
  const env = soExtrato ? { enviadas: 0, sem_cpf: 0, erros: 0 } : await enviarCobrancas(loja, c);
  return { de, ate, cobrancas_espelhadas: espelhadas, ...(ext as Record<string, unknown>), ...(fim as Record<string, unknown>), cobrancas_enviadas: env.enviadas, sem_cpf: env.sem_cpf, erros_envio: env.erros, saldo_asaas: ultima ? Number(ultima.balance) : null };
}

export async function registrarErro(loja: string, msg: string) {
  await admin.from("integracoes_asaas").update({ ultimo_erro: msg }).eq("loja_id", loja);
}

export function usuarioDe(auth: string): SupabaseClient {
  return createClient(SUPABASE_URL, CHAVE_PUBLICA, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
}

export async function exigir(usuario: SupabaseClient, loja: string, perm: string) {
  const { data, error } = await usuario.rpc("tem_permissao", { p_loja: loja, p_perm: perm });
  if (error || data !== true) throw new Falha("Sem permissão na Tesouraria desta loja.", 403);
}

/** Comparação em tempo constante (token do webhook / segredo da rotina). */
export function iguais(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
