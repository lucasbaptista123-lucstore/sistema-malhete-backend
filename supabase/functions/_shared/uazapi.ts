// Cliente UazAPI (WhatsApp) das edge functions do Sistema Malhete.
// Servidor e admintoken são da PLATAFORMA (secrets UAZAPI_URL / UAZAPI_ADMIN_TOKEN); cada loja tem a própria
// instância, cujo token fica no Vault (whatsapp_credenciais).
import { admin, Falha } from "./asaas.ts";

const URL_BASE = (Deno.env.get("UAZAPI_URL") ?? "").replace(/\/+$/, "");
const ADMIN_TOKEN = Deno.env.get("UAZAPI_ADMIN_TOKEN") ?? "";

export type Credencial = { token: string; instancia: string; webhook_token: string; status: string };

export async function uazapi(caminho: string, init: { method?: string; token?: string; admin?: boolean; body?: unknown } = {}) {
  if (!URL_BASE) throw new Falha("WhatsApp ainda não configurado na plataforma.", 500);
  const headers: Record<string, string> = { "Content-Type": "application/json", Accept: "application/json" };
  if (init.admin) headers["admintoken"] = ADMIN_TOKEN;
  if (init.token) headers["token"] = init.token;
  const r = await fetch(`${URL_BASE}${caminho}`, {
    method: init.method ?? "GET", headers, body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const texto = await r.text();
  const json = texto ? (() => { try { return JSON.parse(texto); } catch { return { texto }; } })() : null;
  if (r.status === 401) throw new Falha("O servidor de WhatsApp recusou o acesso desta loja.", 502);
  if (!r.ok) throw new Falha(`WhatsApp: ${json?.error ?? json?.message ?? `erro ${r.status}`}`, 502);
  return json;
}

export const temAdmin = () => !!ADMIN_TOKEN;

export async function credencialWhats(loja: string): Promise<Credencial | null> {
  const { data, error } = await admin.rpc("whatsapp_credenciais", { p_loja: loja });
  if (error) throw new Falha("Não foi possível ler a integração de WhatsApp.", 500);
  return ((data ?? [])[0] as Credencial) ?? null;
}

/** Número brasileiro para o WhatsApp: só dígitos, com 55. */
export function numeroWhats(tel: string) {
  const d = tel.replace(/\D/g, "");
  return d.length <= 11 ? `55${d}` : d;
}

type StatusInst = { instance?: { status?: string; qrcode?: string; paircode?: string; profileName?: string }; status?: { connected?: boolean; jid?: { user?: string } | null } };

/** Consulta a instância e grava o estado (conectado / conectando / desconectado). */
export async function atualizarStatus(loja: string, c: Credencial) {
  const st = (await uazapi("/instance/status", { token: c.token })) as StatusInst;
  const bruto = st.instance?.status ?? (st.status?.connected ? "connected" : "disconnected");
  const status = bruto === "connected" ? "conectado" : bruto === "connecting" ? "conectando" : "desconectado";
  const numero = st.status?.jid?.user ?? null;
  await admin.rpc("whatsapp_atualizar", { p_loja: loja, p_status: status, p_numero: numero, p_perfil: st.instance?.profileName ?? null, p_erro: null });
  return { status, qrcode: st.instance?.qrcode || null, paircode: st.instance?.paircode || null, numero };
}

/** Webhook da instância apontando para esta plataforma (mensagens recebidas e conexão). */
export async function configurarWebhook(loja: string, c: Credencial, supabaseUrl: string) {
  await uazapi("/webhook", {
    method: "POST", token: c.token,
    body: {
      enabled: true,
      url: `${supabaseUrl}/functions/v1/whatsapp-webhook?loja=${loja}&t=${c.webhook_token}`,
      events: ["messages", "connection"],
      excludeMessages: ["wasSentByApi", "isGroupYes", "fromMeYes"],
    },
  });
}

export async function responder(c: Credencial, numero: string, texto: string) {
  await uazapi("/send/text", { method: "POST", token: c.token, body: { number: numero, text: texto, delay: 1200, readchat: true } });
}
