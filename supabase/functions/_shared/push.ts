// Sistema Malhete: notificação no celular (Web Push, padrão VAPID). Inscrições em push_inscricoes.
import webpush from "npm:web-push@3.6.7";
import { admin } from "./asaas.ts";

let configurado = false;
function configurar() {
  if (configurado) return true;
  const pub = Deno.env.get("VAPID_PUBLIC"), priv = Deno.env.get("VAPID_PRIVATE");
  if (!pub || !priv) return false;
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "https://pixel-perfect-replay-6084.lovable.app", pub, priv);
  configurado = true;
  return true;
}

/** Envia a todos os aparelhos dos usuários; apaga inscrições vencidas (404/410). Devolve quantos aparelhos receberam. */
export async function enviarPush(usuarios: string[], titulo: string, corpo: string, url = "/app") {
  if (!usuarios.length || !configurar()) return 0;
  const { data: subs } = await admin.from("push_inscricoes").select("id, endpoint, p256dh, auth").in("user_id", usuarios);
  let ok = 0;
  const carga = JSON.stringify({ titulo, corpo: corpo.length > 180 ? corpo.slice(0, 177) + "…" : corpo, url });
  for (const s of (subs ?? []) as { id: string; endpoint: string; p256dh: string; auth: string }[]) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, carga, { TTL: 86400 });
      ok++;
    } catch (e) {
      const st = (e as { statusCode?: number }).statusCode;
      if (st === 404 || st === 410) await admin.from("push_inscricoes").delete().eq("id", s.id);
      else console.error("push", st, e);
    }
  }
  return ok;
}

/** Usuário (login) do irmão, se ele tiver acesso ao sistema. */
export async function usuarioDoIrmao(irmao: string): Promise<string | null> {
  const { data } = await admin.from("irmaos").select("user_id").eq("id", irmao).maybeSingle();
  return (data?.user_id as string | null) ?? null;
}
