// Sistema Malhete: notificações no celular.
//   chave  {}   devolve a chave pública VAPID (o app usa para inscrever o aparelho)
//   teste  {}   envia uma notificação de teste aos aparelhos de quem chamou
import { CORS, Falha, resposta, usuarioDe } from "../_shared/asaas.ts";
import { enviarPush } from "../_shared/push.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const corpo = await req.json().catch(() => ({}));
    if (corpo.acao === "chave") return resposta({ chave: Deno.env.get("VAPID_PUBLIC") ?? null });
    const auth = req.headers.get("Authorization") ?? "";
    const usuario = usuarioDe(auth);
    const { data: u } = await usuario.auth.getUser();
    if (!u.user) throw new Falha("Faça login.", 401);
    if (corpo.acao === "teste") {
      const n = await enviarPush([u.user.id], "Sistema Malhete", "Notificações ativadas neste aparelho. Tudo certo!", "/app");
      return resposta({ ok: true, aparelhos: n });
    }
    throw new Falha("Ação desconhecida.");
  } catch (e) {
    const st = e instanceof Falha ? e.status : 500;
    return resposta({ erro: e instanceof Error ? e.message : "Erro" }, st);
  }
});
