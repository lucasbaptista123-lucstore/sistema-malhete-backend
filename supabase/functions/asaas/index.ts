// Sistema Malhete — integração Asaas (conta da própria loja), chamada pelo app e pela rotina agendada.
//   conectar            { loja_id, chave, ambiente, conta_id? }  testa a chave, guarda no Vault e cadastra o webhook no Asaas
//   desconectar         { loja_id }                              remove o webhook no Asaas e apaga a chave
//   sincronizar         { loja_id, de?, ate? }                   cobranças + extrato + envio de cobranças
//   enviar_cobrancas    { loja_id }                              mensalidades daqui viram cobrança no Asaas
//   sincronizar_cobranca{ titulo_id }                            reflete no Asaas a edição/cancelamento feito aqui
//   sincronizar_todas   (rotina; cabeçalho x-cron-secret)
//   tronco_pix          { loja_id, valor }                       o irmão gera um PIX do Tronco (lançado sozinho ao pagar)
//   quitar_parcelas     { loja_id, grupo_id }                    o irmão junta as parcelas abertas numa conta só
// Permissões do usuário são conferidas no banco com o JWT de quem chamou.
import {
  admin, asaas, CORS, credencial, enviarCobrancas, EVENTOS_WEBHOOK, exigir, Falha, iguais, registrarErro, resposta,
  garantirEventosWebhook, sincronizarLoja, SUPABASE_URL, usuarioDe,
} from "../_shared/asaas.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Método não permitido" }, 405);

  let loja = "";
  try {
    const corpo = await req.json();

    // ---- rotina agendada (pg_cron)
    if (corpo.acao === "sincronizar_todas") {
      if (!iguais(req.headers.get("x-cron-secret") ?? "", Deno.env.get("CRON_SECRET") ?? "")) throw new Falha("Não autorizado.", 401);
      const { data: lojas, error: eLojas } = await admin.rpc("asaas_lojas_ativas");
      if (eLojas) throw new Falha(`Lojas ativas: ${eLojas.message}`, 500);
      const res: Record<string, unknown> = {};
      for (const l of (lojas ?? []) as string[]) {
        try { res[l] = await sincronizarLoja(l); } catch (e) {
          const msg = e instanceof Error ? e.message : "erro";
          res[l] = { erro: msg };
          await registrarErro(l, msg);
        }
      }
      return resposta({ ok: true, lojas: res });
    }

    const auth = req.headers.get("Authorization");
    if (!auth) throw new Falha("Faça login.", 401);
    const usuario = usuarioDe(auth);

    // ---- edição/cancelamento de conta a receber que já tem cobrança no Asaas
    if (corpo.acao === "sincronizar_cobranca") {
      const { data } = await admin.rpc("asaas_cobranca_do_titulo", { p_titulo: String(corpo.titulo_id ?? "") });
      const t = (data ?? [])[0];
      if (!t) return resposta({ ok: true, nada: true });
      loja = t.loja_id;
      await exigir(usuario, loja, "tesouraria.editar");
      if (Number(t.valor_pago) > 0) return resposta({ ok: true, nada: true });
      const c = await credencial(loja);
      if (t.cancelado) await asaas(c, `/payments/${t.asaas_id}`, { method: "DELETE" });
      else await asaas(c, `/payments/${t.asaas_id}`, { method: "POST", body: { value: Number(t.valor), dueDate: t.vencimento, description: t.descricao } });
      return resposta({ ok: true });
    }

    // ---- o próprio irmão (ex.: adiantou mensalidades): cria no Asaas só as cobranças DELE
    if (corpo.acao === "enviar_minhas") {
      loja = String(corpo.loja_id ?? "");
      if (!/^[0-9a-f-]{36}$/.test(loja)) throw new Falha("Loja inválida.");
      const { data: eu } = await usuario.rpc("meu_irmao_id", { p_loja: loja });
      if (!eu) throw new Falha("Você não é irmão desta loja.", 403);
      const { data: integ } = await admin.from("integracoes_asaas").select("ativo, criar_cobrancas").eq("loja_id", loja).maybeSingle();
      if (!integ?.ativo || !integ.criar_cobrancas) return resposta({ ok: true, enviadas: 0, asaas: false });
      const c = await credencial(loja);
      return resposta({ ok: true, asaas: true, ...(await enviarCobrancas(loja, c, String(eu))) });
    }

    // o irmão gera um PIX do Tronco pelo Asaas; o webhook confirma e lança sozinho (private.tronco_asaas)
    if (corpo.acao === "tronco_pix") {
      loja = String(corpo.loja_id ?? "");
      if (!/^[0-9a-f-]{36}$/.test(loja)) throw new Falha("Loja inválida.");
      const valor = Math.round(Number(corpo.valor) * 100) / 100;
      if (!(valor >= 0.01)) throw new Falha("Informe o valor da contribuição.");
      if (valor > 100000) throw new Falha("Valor alto demais.");
      const { data: eu } = await usuario.rpc("meu_irmao_id", { p_loja: loja });
      if (!eu) throw new Falha("Você não é irmão desta loja.", 403);
      const { data: integ } = await admin.from("integracoes_asaas").select("ativo").eq("loja_id", loja).maybeSingle();
      if (!integ?.ativo) throw new Falha("A Loja não usa o Asaas.", 409);
      const { data: ir } = await admin.from("irmaos").select("nome, cpf, email, telefone").eq("id", eu).single();
      const cpf = String(ir?.cpf ?? "").replace(/\D/g, "");
      if (cpf.length !== 11) throw new Falha("Complete seu CPF em Meu cadastro para gerar o PIX.");
      const c = await credencial(loja);
      const achados = await asaas(c, `/customers?cpfCnpj=${cpf}`);
      const cliente = achados?.data?.[0]?.id ?? (await asaas(c, "/customers", { method: "POST", body: {
        name: ir!.nome, cpfCnpj: cpf, email: ir!.email ?? undefined,
        mobilePhone: String(ir!.telefone ?? "").replace(/\D/g, "") || undefined, externalReference: eu,
      } })).id;
      const { data: contrib, error: e1 } = await admin.from("tronco_contribuicoes").insert({
        loja_id: loja, irmao_id: eu, valor, txid: `TRONCO${Date.now()}`, status: "aguardando", origem: "asaas",
      }).select("id").single();
      if (e1) throw new Error(e1.message);
      const hoje = new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10);
      const pg = await asaas(c, "/payments", { method: "POST", body: {
        customer: cliente, billingType: "PIX", value: valor, dueDate: hoje,
        description: "Tronco de Beneficência", externalReference: `tronco:${contrib.id}`,
      } });
      await admin.from("tronco_contribuicoes").update({ asaas_id: pg.id }).eq("id", contrib.id);
      const qr = await asaas(c, `/payments/${pg.id}/pixQrCode`);
      return resposta({ ok: true, id: contrib.id, imagem: qr.encodedImage, copia_e_cola: qr.payload });
    }

    // o irmão junta as parcelas abertas numa conta só; as cobranças antigas são apagadas no Asaas
    if (corpo.acao === "quitar_parcelas") {
      loja = String(corpo.loja_id ?? "");
      const grupo = String(corpo.grupo_id ?? "");
      if (!/^[0-9a-f-]{36}$/.test(loja) || !/^[0-9a-f-]{36}$/.test(grupo)) throw new Falha("Dados inválidos.");
      const { data: r, error } = await usuario.rpc("quitar_parcelas", { p_grupo: grupo });
      if (error) throw new Falha(error.message);
      const res = r as { titulo: string; total: number; parcelas: number; asaas_ids: string[] };
      const { data: integ } = await admin.from("integracoes_asaas").select("ativo, criar_cobrancas").eq("loja_id", loja).maybeSingle();
      let enviadas = 0;
      if (integ?.ativo) {
        const c = await credencial(loja);
        for (const id of res.asaas_ids ?? []) {
          try {
            await asaas(c, `/payments/${id}`, { method: "DELETE" });
          } catch (e) {
            console.error("apagar cobrança no Asaas", id, e);
          }
        }
        if (integ.criar_cobrancas) {
          const { data: eu } = await usuario.rpc("meu_irmao_id", { p_loja: loja });
          enviadas = (await enviarCobrancas(loja, c, String(eu))).enviadas;
        }
      }
      return resposta({ ok: true, ...res, enviadas });
    }

    loja = String(corpo.loja_id ?? "");
    if (!/^[0-9a-f-]{36}$/.test(loja)) throw new Falha("Loja inválida.");
    await exigir(usuario, loja, "tesouraria.editar");

    if (corpo.acao === "conectar") {
      const chave = String(corpo.chave ?? "").trim();
      if (chave.length < 20) throw new Falha("Cole a chave da API do Asaas.");
      // ambiente descoberto pela chave: tenta o provável (pelo prefixo) e, se recusar, o outro
      const escolhido = corpo.ambiente === "sandbox" || corpo.ambiente === "producao" ? corpo.ambiente : null;
      const ordem = escolhido ? [escolhido] : chave.includes("_hmlg_") ? ["sandbox", "producao"] : ["producao", "sandbox"];
      let ambiente = ordem[0]!;
      let saldo: { balance?: number } | null = null;
      for (const amb of ordem) {
        try {
          saldo = await asaas({ ambiente: amb, chave }, "/finance/balance");
          ambiente = amb;
          break;
        } catch (e) {
          if (!(e instanceof Falha) || e.status !== 401 || amb === ordem[ordem.length - 1]) throw e;
        }
      }

      const { data: antiga } = await admin.from("integracoes_asaas").select("webhook_id, ambiente").eq("loja_id", loja).maybeSingle();
      const { data: conta, error } = await usuario.rpc("asaas_conectar", { p_loja: loja, p_chave: chave, p_ambiente: ambiente, p_conta: corpo.conta_id ?? null });
      if (error) throw new Falha(error.message);

      // webhook: o Asaas avisa na hora cada cobrança criada, paga, alterada ou estornada
      let aviso: string | null = null;
      try {
        if (antiga?.webhook_id) await asaas({ ambiente, chave }, `/webhooks/${antiga.webhook_id}`, { method: "DELETE" }).catch(() => null);
        const { data: integ } = await admin.from("integracoes_asaas").select("webhook_token").eq("loja_id", loja).single();
        const { data: u } = await usuario.auth.getUser();
        const wh = await asaas({ ambiente, chave }, "/webhooks", { method: "POST", body: {
          name: "Sistema Malhete", url: `${SUPABASE_URL}/functions/v1/asaas-webhook?loja=${loja}`,
          email: u.user?.email, enabled: true, interrupted: false, apiVersion: 3,
          authToken: integ!.webhook_token, sendType: "SEQUENTIALLY", events: EVENTOS_WEBHOOK,
        } });
        await admin.rpc("asaas_registrar_webhook", { p_loja: loja, p_webhook_id: wh.id });
      } catch (e) {
        aviso = `Conectado, mas o aviso automático não foi cadastrado no Asaas (${e instanceof Error ? e.message : "erro"}). A sincronização a cada 6 horas continua funcionando.`;
        await registrarErro(loja, aviso);
      }
      return resposta({ ok: true, conta_id: conta, saldo: saldo?.balance ?? null, aviso });
    }

    if (corpo.acao === "desconectar") {
      const { data: integ } = await admin.from("integracoes_asaas").select("webhook_id").eq("loja_id", loja).maybeSingle();
      if (integ?.webhook_id) {
        const c = await credencial(loja).catch(() => null);
        if (c) await asaas(c, `/webhooks/${integ.webhook_id}`, { method: "DELETE" }).catch(() => null);
      }
      const { error } = await usuario.rpc("asaas_desconectar", { p_loja: loja });
      if (error) throw new Falha(error.message);
      return resposta({ ok: true });
    }

    if (corpo.acao === "sincronizar") {
      const r = await sincronizarLoja(loja, corpo.de, corpo.ate);
      const avisos = await garantirEventosWebhook(loja, await credencial(loja)).catch((e) => `não atualizado: ${e instanceof Error ? e.message : e}`);
      return resposta({ ok: true, ...r, avisos_de_saida: avisos });
    }

    if (corpo.acao === "enviar_cobrancas") {
      return resposta({ ok: true, ...(await enviarCobrancas(loja, await credencial(loja))) });
    }

    throw new Falha("Ação desconhecida.");
  } catch (e) {
    const f = e instanceof Falha ? e : new Falha("Erro inesperado na integração.", 500);
    if (!(e instanceof Falha)) console.error(e);
    if (loja && f.status !== 403 && f.status !== 401) await registrarErro(loja, f.message);
    return resposta({ erro: f.message }, f.status);
  }
});
