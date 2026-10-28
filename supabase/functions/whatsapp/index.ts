// Sistema Malhete — WhatsApp da loja (UazAPI), chamado pelo app.
//   conectar     { loja_id }   cria a instância (se a plataforma tiver admintoken) ou usa a já vinculada,
//                              aponta o webhook e devolve o QR Code para ler no celular
//   status       { loja_id }   estado da conexão (e QR atualizado enquanto conecta)
//   desconectar  { loja_id }
//   enviar       { envio_id }  dispara em lote, com intervalo aleatório entre mensagens (contra bloqueio)
// Permissões conferidas no banco com o JWT de quem chamou.
import { admin, CORS, Falha, iguais, resposta, SUPABASE_URL, usuarioDe } from "../_shared/asaas.ts";
import { enviarPush, usuarioDoIrmao } from "../_shared/push.ts";
import { atualizarStatus, configurarWebhook, credencialWhats, numeroWhats, temAdmin, uazapi, type Credencial } from "../_shared/uazapi.ts";

async function exigirRpc(usuario: ReturnType<typeof usuarioDe>, fn: string, args: Record<string, unknown>, msg: string) {
  const { data, error } = await usuario.rpc(fn, args);
  if (error || data !== true) throw new Falha(msg, 403);
}

async function pode(usuario: ReturnType<typeof usuarioDe>, loja: string, perms: string[]) {
  for (const p of perms) {
    const { data } = await usuario.rpc("tem_permissao", { p_loja: loja, p_perm: p });
    if (data === true) return true;
  }
  return false;
}

const RODAPE_CONVOCACAO = "Toque em um dos botões. Se não aparecerem, responda 1 (sim) ou 2 (não).";
const RODAPE_JUSTIFICATIVA = "Se o botão não aparecer, basta responder esta mensagem com o motivo.";

type Envio = { id: string; loja_id: string; tipo: string; mensagem: string; canal: string };

/** Dispara um envio em lote pelo /sender/advanced (intervalo aleatório contra bloqueio). */
async function disparar(envio: Envio) {
  const c = await credencialWhats(envio.loja_id);
  if (!c || c.status !== "conectado") throw new Falha("O WhatsApp da loja não está conectado.");

  const { data: dests } = await admin.from("envio_destinatarios").select("id, telefone, token, irmaos(nome)").eq("envio_id", envio.id).eq("status", "pendente");
  const lista = ((dests ?? []) as unknown as { id: string; telefone: string | null; token: string; irmaos: { nome: string } | null }[])
    .filter((d) => d.telefone);
  // "{nome}" → primeiro nome de cada irmão; sem o marcador, a mensagem já começa chamando pelo nome
  const texto = (d: (typeof lista)[number]) => {
    const nome = (d.irmaos?.nome ?? "").trim().split(/\s+/)[0] ?? "";
    if (envio.mensagem.includes("{nome}")) return envio.mensagem.replaceAll("{nome}", nome);
    return nome ? `Irmão ${nome},\n\n${envio.mensagem}` : envio.mensagem;
  };
  if (!lista.length) return { enviados: 0, minutos: 0 };

  const messages = lista.map((d) => envio.tipo === "convocacao"
    ? { number: numeroWhats(d.telefone!), type: "button", text: texto(d), footerText: RODAPE_CONVOCACAO,
    choices: [`✅ Sim, estarei presente|rsvp:sim:${d.token}`, `❌ Não poderei ir|rsvp:nao:${d.token}`] }
    : envio.tipo === "justificativa"
      ? { number: numeroWhats(d.telefone!), type: "button", text: texto(d), footerText: RODAPE_JUSTIFICATIVA,
      choices: [`Justificar ausência|just:ok:${d.token}`] }
      : { number: numeroWhats(d.telefone!), type: "text", text: texto(d) });

  const lote = await uazapi("/sender/advanced", {
    method: "POST", token: c.token,
    body: { delayMin: 8, delayMax: 20, info: `Malhete ${envio.tipo} ${envio.id}`, messages },
  });
  await admin.from("envio_destinatarios").update({ status: "enviado", enviado_em: new Date().toISOString() }).in("id", lista.map((d) => d.id));
  await admin.from("envios").update({ lote_externo: lote?.folder_id ?? null }).eq("id", envio.id);
  if (envio.tipo === "justificativa") await admin.rpc("whatsapp_abrir_justificativas", { p_envio: envio.id });
  // aproximação: ~14s por mensagem
  return { enviados: lista.length, minutos: Math.max(1, Math.round((lista.length * 14) / 60)) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Método não permitido" }, 405);
  try {
    const corpo0 = await req.clone().json().catch(() => ({}));

    // ---- rotina (pg_cron a cada 2 min): envia os avisos da fila aos poucos, loja por loja
    if (corpo0.acao === "processar_fila") {
      if (!iguais(req.headers.get("x-cron-secret") ?? "", Deno.env.get("CRON_SECRET") ?? "")) throw new Falha("Não autorizado.", 401);
      const { data: fila } = await admin.rpc("notificacoes_proximas", { p_por_loja: 4 });
      const creds = new Map<string, Credencial | null>();
      let enviados = 0, falhas = 0;
      for (const n of (fila ?? []) as { id: string; loja_id: string; telefone: string; mensagem: string }[]) {
        if (!creds.has(n.loja_id)) creds.set(n.loja_id, await credencialWhats(n.loja_id));
        const c = creds.get(n.loja_id);
        if (!c) continue;
        try {
          await uazapi("/send/text", { method: "POST", token: c.token, body: { number: numeroWhats(n.telefone), text: n.mensagem, linkPreview: true, delay: 1500 } });
          await admin.from("notificacoes").update({ status: "enviado", enviado_em: new Date().toISOString(), erro: null }).eq("id", n.id);
          enviados++;
          // o mesmo aviso no celular, para quem ativou as notificações
          try {
            const { data: nt } = await admin.from("notificacoes").select("irmao_id").eq("id", n.id).single();
            const uid = nt ? await usuarioDoIrmao(nt.irmao_id as string) : null;
            if (uid) await enviarPush([uid], "Sistema Malhete", n.mensagem);
          } catch (e) {
            console.error("push da fila", n.id, e);
          }
        } catch (e) {
          await admin.from("notificacoes").update({ status: "falhou", erro: e instanceof Error ? e.message : "erro" }).eq("id", n.id);
          falhas++;
        }
        // intervalo entre mensagens da mesma loja (contra bloqueio)
        await new Promise((r) => setTimeout(r, 4000 + Math.random() * 6000));
      }
      return resposta({ ok: true, enviados, falhas });
    }

    // ---- rotina (pg_cron 9h): no dia da sessão, lembra quem foi convocado e não respondeu
    if (corpo0.acao === "lembretes_sessao") {
      if (!iguais(req.headers.get("x-cron-secret") ?? "", Deno.env.get("CRON_SECRET") ?? "")) throw new Falha("Não autorizado.", 401);
      const { data: ids, error } = await admin.rpc("criar_lembretes_sessao");
      if (error) throw new Falha(error.message, 500);
      let enviados = 0;
      for (const id of (ids ?? []) as string[]) {
        const { data: envio } = await admin.from("envios").select("id, loja_id, tipo, mensagem, canal").eq("id", id).maybeSingle();
        if (!envio) continue;
        try { enviados += (await disparar(envio)).enviados; } catch (e) { console.error("lembrete", id, e); }
      }
      return resposta({ ok: true, lembretes: (ids ?? []).length, enviados });
    }

    const auth = req.headers.get("Authorization");
    if (!auth) throw new Falha("Faça login.", 401);
    const usuario = usuarioDe(auth);
    const corpo = corpo0;

    // ---- disparo de um envio
    if (corpo.acao === "enviar") {
      const { data: envio } = await admin.from("envios").select("id, loja_id, tipo, mensagem, canal, lote_externo").eq("id", String(corpo.envio_id ?? "")).maybeSingle();
      if (!envio) throw new Falha("Envio não encontrado.");
      const perms = envio.tipo === "convocacao" ? ["sessoes.convocar"] : envio.tipo === "justificativa" ? ["chancelaria.editar", "sessoes.convocar"] : ["comunicacao.enviar"];
      if (!(await pode(usuario, envio.loja_id, perms))) throw new Falha("Sem permissão para este envio.", 403);
      if (envio.canal !== "whatsapp") throw new Falha("Este envio não é pelo WhatsApp.");
      return resposta({ ok: true, ...(await disparar(envio)) });
    }

    const loja = String(corpo.loja_id ?? "");
    if (!/^[0-9a-f-]{36}$/.test(loja)) throw new Falha("Loja inválida.");

    if (corpo.acao === "status") {
      if (!(await pode(usuario, loja, ["loja.config", "secretaria.editar", "sessoes.convocar", "chancelaria.editar"]))) throw new Falha("Sem permissão.", 403);
      const c = await credencialWhats(loja);
      if (!c) return resposta({ ok: true, status: "sem_instancia" });
      return resposta({ ok: true, ...(await atualizarStatus(loja, c)) });
    }

    await exigirRpc(usuario, "whatsapp_pode_configurar", { p_loja: loja }, "Só o Venerável ou o Secretário conectam o WhatsApp da loja.");

    if (corpo.acao === "conectar") {
      let c = await credencialWhats(loja);
      if (!c) {
        if (!temAdmin()) throw new Falha("O WhatsApp ainda não foi liberado para esta loja. Fale com o suporte do Sistema Malhete.");
        const nova = await uazapi("/instance/create", { method: "POST", admin: true, body: { name: `malhete-${loja.slice(0, 8)}`, systemName: "Sistema Malhete" } });
        if (!nova?.token) throw new Falha("Não foi possível criar o WhatsApp da loja.", 502);
        await admin.rpc("whatsapp_salvar", { p_loja: loja, p_instancia: nova.name ?? `malhete-${loja.slice(0, 8)}`, p_token: nova.token });
        c = await credencialWhats(loja);
      }
      await configurarWebhook(loja, c!, SUPABASE_URL);
      const atual = await atualizarStatus(loja, c!);
      if (atual.status === "conectado") return resposta({ ok: true, ...atual });
      await uazapi("/instance/connect", { method: "POST", token: c!.token, body: {} });
      await new Promise((r) => setTimeout(r, 1500));
      return resposta({ ok: true, ...(await atualizarStatus(loja, c!)) });
    }

    if (corpo.acao === "desconectar") {
      const c = await credencialWhats(loja);
      if (c) {
        await uazapi("/instance/disconnect", { method: "POST", token: c.token, body: {} }).catch(() => null);
        await admin.rpc("whatsapp_atualizar", { p_loja: loja, p_status: "desconectado", p_numero: null, p_perfil: null, p_erro: null });
      }
      return resposta({ ok: true });
    }

    throw new Falha("Ação desconhecida.");
  } catch (e) {
    const f = e instanceof Falha ? e : new Falha("Erro inesperado no WhatsApp.", 500);
    if (!(e instanceof Falha)) console.error(e);
    return resposta({ erro: f.message }, f.status);
  }
});
