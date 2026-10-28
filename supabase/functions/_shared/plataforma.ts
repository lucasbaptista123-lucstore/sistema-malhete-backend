// Conta Asaas DA PLATAFORMA (cobra as assinaturas das Lojas). Nunca misturar com a conta de cada Loja.
import { admin, asaas, Falha } from "./asaas.ts";

export type CredPlataforma = { chave: string; ambiente: string; webhook_id: string | null; webhook_token: string };

export async function credPlataforma(): Promise<CredPlataforma> {
  const { data, error } = await admin.rpc("plataforma_asaas_credencial");
  if (error) throw new Falha("Não foi possível ler a conta da plataforma.", 500);
  const c = (data ?? [])[0];
  if (!c) throw new Falha("A cobrança da plataforma ainda não foi configurada. Tente mais tarde.", 503);
  return c as CredPlataforma;
}

export const EVENTOS_ASSINATURA = [
  "PAYMENT_CREATED", "PAYMENT_UPDATED", "PAYMENT_CONFIRMED", "PAYMENT_RECEIVED", "PAYMENT_OVERDUE",
  "PAYMENT_DELETED", "PAYMENT_RESTORED", "PAYMENT_REFUNDED", "PAYMENT_RECEIVED_IN_CASH_UNDONE",
];

/** Espelha uma cobrança da assinatura no banco (status, vencimento, link de pagamento). */
export async function espelharFatura(pg: Record<string, unknown>, evento?: string) {
  if (!pg.subscription) return "sem assinatura";
  const { data, error } = await admin.rpc("plataforma_espelhar_fatura", {
    p_assinatura: String(pg.subscription), p_id: String(pg.id), p_valor: Number(pg.value),
    p_vencimento: String(pg.dueDate), p_status: evento === "PAYMENT_DELETED" || pg.deleted ? "DELETED" : String(pg.status),
    p_forma: (pg.billingType as string) ?? null, p_link: (pg.invoiceUrl as string) ?? null,
    p_pago: (pg.paymentDate as string) ?? (pg.clientPaymentDate as string) ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

/** Lê todas as cobranças de uma assinatura no Asaas e espelha. */
export async function sincronizarFaturas(c: CredPlataforma, assinatura: string) {
  const r = await asaas(c, `/subscriptions/${assinatura}/payments?limit=100`);
  const lista = (r.data ?? []) as Record<string, unknown>[];
  for (const pg of lista) await espelharFatura({ ...pg, subscription: assinatura });
  return lista.length;
}

type EtapaRegua = { etapa: string; ativo: boolean; email: boolean; sms: boolean; whatsapp: boolean; dias: number | null };

/**
 * Régua de cobrança: ajusta os avisos automáticos do Asaas (e-mail, SMS, WhatsApp) do cliente conforme plataforma_regua.
 * criada = PAYMENT_CREATED; antes/no_dia = PAYMENT_DUEDATE_WARNING (offset > 0 / = 0); vencida/lembrete = PAYMENT_OVERDUE
 * (o de menor intervalo / o outro); paga = PAYMENT_RECEIVED.
 */
export async function aplicarRegua(c: CredPlataforma, cliente: string) {
  const { data: regua, error } = await admin.rpc("plataforma_regua_ler");
  if (error) throw new Error(error.message);
  const etapas = new Map(((regua ?? []) as EtapaRegua[]).map((e) => [e.etapa, e]));
  const r = await asaas(c, `/customers/${cliente}/notifications`);
  const lista = (r.data ?? []) as { id: string; event: string; scheduleOffset: number }[];
  const aviso = lista.filter((n) => n.event === "PAYMENT_DUEDATE_WARNING");
  const atraso = lista.filter((n) => n.event === "PAYMENT_OVERDUE").sort((a, b) => a.scheduleOffset - b.scheduleOffset);
  const alvo: [string, { id: string } | undefined][] = [
    ["criada", lista.find((n) => n.event === "PAYMENT_CREATED")],
    ["antes", aviso.find((n) => n.scheduleOffset !== 0) ?? aviso[1]],
    ["no_dia", aviso.find((n) => n.scheduleOffset === 0) ?? aviso[0]],
    ["vencida", atraso[0]],
    ["lembrete", atraso[1]],
    ["paga", lista.find((n) => n.event === "PAYMENT_RECEIVED")],
  ];
  const notifications = alvo.flatMap(([k, n]) => {
    const e = etapas.get(k);
    if (!n || !e) return [];
    return [{
      id: n.id, enabled: e.ativo, emailEnabledForCustomer: e.email, smsEnabledForCustomer: e.sms,
      whatsappEnabledForCustomer: e.whatsapp, emailEnabledForProvider: false, smsEnabledForProvider: false,
      ...(k === "antes" || k === "lembrete" ? { scheduleOffset: e.dias ?? (k === "antes" ? 5 : 7) } : k === "no_dia" ? { scheduleOffset: 0 } : {}),
    }];
  });
  if (notifications.length) await asaas(c, "/notifications/batch", { method: "PUT", body: { customer: cliente, notifications } });
  return notifications.length;
}
