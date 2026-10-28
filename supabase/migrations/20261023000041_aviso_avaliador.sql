-- Sistema Malhete — quem avalia é avisado pelo WhatsApp quando chega (ou volta corrigido) um trabalho:
-- o Vigilante que acompanha o grau do trabalho (2º → Aprendiz, 1º → Companheiro); sem ele (ou grau de Mestre),
-- o Venerável. O autor nunca recebe como avaliador.

create or replace function private.aviso_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_nome text;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
  a record;
  v_avisou boolean := false;
begin
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  if tg_op = 'INSERT' or (old.status <> 'enviado' and new.status = 'enviado') then
    perform private.notificar(new.loja_id, new.irmao_id, 'trabalho_recebido', new.id,
      format('Olá, %s! Seu trabalho “%s” foi recebido e está em avaliação.', private.primeiro_nome(v_nome), new.titulo));
    -- avaliadores do grau
    for a in
      select distinct i.id, i.nome from public.irmaos i
      join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
      join public.loja_cargos c on c.id = m.cargo_id
      where i.loja_id = new.loja_id and i.situacao = 'ativo' and i.id <> new.irmao_id
        and 'trabalhos.avaliar' = any (c.permissoes) and c.grau_acompanhado = new.grau
    loop
      v_avisou := true;
      perform private.notificar(new.loja_id, a.id, 'trabalho_recebido', new.id,
        format('Irmão %s, %s um trabalho para avaliar: “%s”, do irmão %s.%sAvalie em: %s/app/trabalhos/%s',
               private.primeiro_nome(a.nome), case when tg_op = 'INSERT' then 'chegou' else 'voltou corrigido' end,
               new.titulo, v_nome, E'\n', v_url, new.id));
    end loop;
    if not v_avisou then
      for a in
        select distinct i.id, i.nome from public.irmaos i
        join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
        join public.loja_cargos c on c.id = m.cargo_id
        where i.loja_id = new.loja_id and i.situacao = 'ativo' and c.codigo = 'veneravel'
          and i.id <> new.irmao_id
      loop
        perform private.notificar(new.loja_id, a.id, 'trabalho_recebido', new.id,
          format('Irmão %s, %s um trabalho para avaliar: “%s”, do irmão %s.%sAvalie em: %s/app/trabalhos/%s',
                 private.primeiro_nome(a.nome), case when tg_op = 'INSERT' then 'chegou' else 'voltou corrigido' end,
                 new.titulo, v_nome, E'\n', v_url, new.id));
      end loop;
    end if;
  elsif new.status is distinct from old.status and new.status in ('aprovado', 'ajustes') then
    perform private.notificar(new.loja_id, new.irmao_id, 'trabalho_avaliado', new.id,
      case when new.status = 'aprovado'
        then format('Olá, %s! Seu trabalho “%s” foi avaliado e aprovado.%s', private.primeiro_nome(v_nome), new.titulo,
                    case when new.parecer is not null then E'\n' || 'Parecer: ' || new.parecer else '' end)
        else format('Olá, %s! Seu trabalho “%s” voltou com ressalvas:%s%s%sPara corrigir e reenviar: %s/app/trabalhos/%s',
                    private.primeiro_nome(v_nome), new.titulo, E'\n', coalesce(new.parecer, ''), E'\n\n', v_url, new.id)
      end);
  end if;
  return new;
end $$;
revoke all on all functions in schema private from public, anon, authenticated;
