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
