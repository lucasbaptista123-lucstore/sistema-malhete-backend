// Sistema Malhete: assinatura das Lojas (conta Asaas da plataforma).
//   conectar   { chave, ambiente? }                 dono da plataforma: guarda a chave no Vault e cadastra o webhook
//   assinar    { loja_id, ciclo: mensal|anual, forma: PIX|BOLETO }   Tesoureiro (tesouraria.editar), mesmo com a Loja travada
//   faturas    { loja_id }                           relê as cobranças no Asaas (Venerável ou Tesoureiro)
//   cancelar   { loja_id, motivo }                   Venerável (loja.config); acesso segue até o fim do período pago
import { admin, asaas, CORS, Falha, resposta, SUPABASE_URL, usuarioDe } from "../_shared/asaas.ts";
import { credPlataforma, EVENTOS_ASSINATURA, sincronizarFaturas } from "../_shared/plataforma.ts";

const hojeBr = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10);
const somaDias = (iso: string, d: number) => new Date(new Date(iso + "T12:00:00Z").getTime() + d * 864e5).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const corpo = await req.json().catch(() => ({}));
    const auth = req.headers.get("Authorization");
    if (!auth) throw new Falha("Faça login.", 401);
    const usuario = usuarioDe(auth);

    if (corpo.acao === "conectar") {
      const { data: dono } = await usuario.rpc("eh_admin_plataforma");
      if (dono !== true) throw new Falha("Acesso restrito.", 403);
      const chave = String(corpo.chave ?? "").trim();
      if (chave.length < 20) throw new Falha("Cole a chave da API do Asaas da plataforma.");
      const ordem = corpo.ambiente === "sandbox" || corpo.ambiente === "producao" ? [corpo.ambiente] : chave.includes("_hmlg_") ? ["sandbox", "producao"] : ["producao", "sandbox"];
      let ambiente = "";
      let conta: Record<string, unknown> | null = null;
      for (const amb of ordem) {
        try { conta = await asaas({ ambiente: amb, chave }, "/myAccount"); ambiente = amb; break; } catch (e) {
          if (!(e instanceof Falha) || e.status !== 401 || amb === ordem[ordem.length - 1]) throw e;
        }
      }
      const { error } = await usuario.rpc("plataforma_asaas_conectar", { p_chave: chave, p_ambiente: ambiente });
      if (error) throw new Falha(error.message);
      const c = await credPlataforma();
      let aviso: string | null = null;
      try {
        if (c.webhook_id) await asaas(c, `/webhooks/${c.webhook_id}`, { method: "DELETE" }).catch(() => null);
        const { data: u } = await usuario.auth.getUser();
        const wh = await asaas(c, "/webhooks", { method: "POST", body: {
          name: "Malhete assinaturas", url: `${SUPABASE_URL}/functions/v1/plataforma-webhook`, email: u.user?.email,
          enabled: true, interrupted: false, apiVersion: 3, authToken: c.webhook_token, sendType: "SEQUENTIALLY", events: EVENTOS_ASSINATURA,
        } });
        await admin.from("plataforma_asaas").update({ webhook_id: wh.id }).eq("id", 1);
      } catch (e) {
        aviso = `Conta conectada, mas o aviso de pagamento não foi cadastrado (${e instanceof Error ? e.message : "erro"}).`;
      }
      return resposta({ ok: true, ambiente, conta: conta?.name ?? conta?.companyName ?? null, aviso });
    }

    const loja = String(corpo.loja_id ?? "");
    if (!/^[0-9a-f-]{36}$/.test(loja)) throw new Falha("Loja inválida.");
    const { data: eu, error: eEu } = await usuario.rpc("minha_assinatura", { p_loja: loja });
    if (eEu || !eu) throw new Falha("Sem acesso a esta Loja.", 403);
    const { data: a } = await admin.from("assinaturas").select("*").eq("loja_id", loja).single();
    if (!a) throw new Falha("Assinatura não encontrada.", 404);
    if (a.status === "vitalicia") throw new Falha("Esta Loja tem acesso vitalício, sem cobrança.");

    if (corpo.acao === "assinar") {
      if (!eu.pode_pagar) throw new Falha("Quem assina e paga é o Tesoureiro.", 403);
      const ciclo = corpo.ciclo === "anual" ? "anual" : "mensal";
      const forma = String(corpo.forma ?? "PIX");
      const formas = String(eu.formas ?? "PIX,BOLETO").split(",");
      if (!formas.includes(forma)) throw new Falha("Forma de pagamento indisponível.");
      const valor = Number(ciclo === "anual" ? eu.preco_anual : eu.preco_mensal);
      const c = await credPlataforma();

      const { data: l } = await admin.from("lojas").select("nome, numero, cnpj").eq("id", loja).single();
      const { data: u } = await usuario.auth.getUser();
      const { data: ir } = await admin.from("irmaos").select("cpf, nome, telefone").eq("loja_id", loja).eq("user_id", u.user!.id).single();
      const documento = String(l?.cnpj || ir?.cpf || "").replace(/\D/g, "");
      if (documento.length !== 11 && documento.length !== 14) throw new Falha("Cadastre o CNPJ da Loja (Configurações) ou o seu CPF para emitir a cobrança.");

      let cliente = a.asaas_cliente_id as string | null;
      if (!cliente) {
        const cl = await asaas(c, "/customers", { method: "POST", body: {
          name: `${String(l!.nome).trim()}${l!.numero ? ` nº ${l!.numero}` : ""}`, cpfCnpj: documento,
          email: u.user?.email, mobilePhone: ir?.telefone ?? undefined, externalReference: loja,
        } });
        cliente = cl.id as string;
      }
      const hoje = hojeBr();
      const inicio = a.status === "teste" && a.teste_ate && a.teste_ate > hoje ? a.teste_ate
        : a.status === "cancelada" && a.acesso_ate && a.acesso_ate > hoje ? a.acesso_ate : hoje;
      const corpoAss = { billingType: forma, value: valor, cycle: ciclo === "anual" ? "YEARLY" : "MONTHLY",
        description: `Sistema Malhete · plano ${ciclo}`, externalReference: loja };
      let sub = a.asaas_assinatura_id as string | null;
      if (sub) {
        await asaas(c, `/subscriptions/${sub}`, { method: "PUT", body: { ...corpoAss, updatePendingPayments: true } });
      } else {
        const s = await asaas(c, "/subscriptions", { method: "POST", body: { ...corpoAss, customer: cliente, nextDueDate: inicio } });
        sub = s.id as string;
      }
      const { error } = await admin.rpc("plataforma_registrar_assinatura", {
        p_loja: loja, p_ciclo: ciclo, p_valor: valor, p_forma: forma, p_cliente: cliente, p_assinatura: sub, p_proximo: inicio,
      });
      if (error) throw new Falha(error.message, 500);
      await sincronizarFaturas(c, sub!);
      return resposta({ ok: true, primeiro_vencimento: inicio });
    }

    if (corpo.acao === "faturas") {
      if (!eu.ve_detalhes) throw new Falha("Sem acesso.", 403);
      if (!a.asaas_assinatura_id) return resposta({ ok: true, lidas: 0 });
      return resposta({ ok: true, lidas: await sincronizarFaturas(await credPlataforma(), a.asaas_assinatura_id) });
    }

    if (corpo.acao === "cancelar") {
      if (!eu.pode_cancelar) throw new Falha("Só o Venerável cancela a assinatura.", 403);
      const motivo = String(corpo.motivo ?? "").trim();
      if (!motivo) throw new Falha("Conte o motivo do cancelamento.");
      if (a.asaas_assinatura_id) await asaas(await credPlataforma(), `/subscriptions/${a.asaas_assinatura_id}`, { method: "DELETE" });
      const hoje = hojeBr();
      const ate = a.status === "teste" ? a.teste_ate : a.proximo_vencimento && a.proximo_vencimento > hoje ? somaDias(a.proximo_vencimento, -1) : hoje;
      const { error } = await admin.rpc("plataforma_cancelar", { p_loja: loja, p_motivo: motivo, p_acesso_ate: ate });
      if (error) throw new Falha(error.message, 500);
      return resposta({ ok: true, acesso_ate: ate });
    }
    throw new Falha("Ação desconhecida.");
  } catch (e) {
    const st = e instanceof Falha ? e.status : 500;
    if (!(e instanceof Falha)) console.error("plataforma", e);
    return resposta({ erro: e instanceof Error ? e.message : "Erro" }, st);
  }
});
