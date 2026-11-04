// Sistema Malhete: cria a conta de quem chega pelo link de convite, SEM e-mail de confirmação (04/11/2026).
// O e-mail embutido do Supabase manda só 2 por hora e travou o cadastro dos irmãos; o convite já é a prova:
// o link vai pelo WhatsApp da Loja ao telefone do irmão, vale 14 dias e é usado uma vez (aceitar_convite).
// Sem JWT (o irmão ainda não tem conta). Conta já existente e confirmada: o app só faz login.
import { admin, CORS, Falha, resposta } from "../_shared/asaas.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    if (req.method !== "POST") throw new Falha("Método não permitido", 405);
    const corpo = await req.json().catch(() => ({})) as { token?: string; email?: string; senha?: string };
    const token = String(corpo.token ?? "");
    const email = String(corpo.email ?? "").trim().toLowerCase();
    const senha = String(corpo.senha ?? "");
    if (!/^[0-9a-f]{32,}$/.test(token)) throw new Falha("Convite inválido.");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Falha("Informe um e-mail válido.");
    if (senha.length < 6) throw new Falha("A senha precisa ter pelo menos 6 caracteres.");

    const { data: c } = await admin.from("convites").select("id, usado_em, expira_em").eq("token", token).maybeSingle();
    if (!c || c.usado_em || new Date(c.expira_em as string) < new Date()) {
      throw new Falha("Convite inválido ou vencido. Peça um novo ao Secretário.");
    }

    const { error } = await admin.auth.admin.createUser({
      email, password: senha, email_confirm: true, user_metadata: { convite: token },
    });
    if (!error) return resposta({ ok: true, criada: true });

    // e-mail já cadastrado: se ficou sem confirmar (tentativa que travou no e-mail), confirma com esta senha
    const { data: ex } = await admin.rpc("convite_conta_existente", { p_email: email });
    const conta = (ex ?? [])[0] as { id: string; confirmado: boolean } | undefined;
    if (!conta) throw new Falha("Não foi possível criar a conta. Tente de novo em instantes.", 500);
    if (!conta.confirmado) {
      const { error: e2 } = await admin.auth.admin.updateUserById(conta.id, {
        password: senha, email_confirm: true, user_metadata: { convite: token },
      });
      if (e2) throw new Falha("Não foi possível criar a conta. Tente de novo em instantes.", 500);
      return resposta({ ok: true, criada: true });
    }
    return resposta({ ok: true, ja_existe: true });
  } catch (e) {
    const f = e instanceof Falha ? e : new Falha("Erro inesperado.", 500);
    if (!(e instanceof Falha)) console.error("convite", e);
    return resposta({ erro: f.message }, f.status);
  }
});
