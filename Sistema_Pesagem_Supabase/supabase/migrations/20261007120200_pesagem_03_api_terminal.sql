-- =============================================================================
--  TERMINAL DE PESAGEM — 03 · API DO TERMINAL (ESP32)
-- -----------------------------------------------------------------------------
--  O ESP32 NÃO acessa tabelas. Ele chama somente 4 RPCs via PostgREST:
--
--    POST /rest/v1/rpc/terminal_heartbeat    { "p_dados": {...} }
--    POST /rest/v1/rpc/terminal_catalogo     {}
--    POST /rest/v1/rpc/terminal_evento       { "p_tipo": "...", "p_event_id": "uuid", "p_dados": {...} }
--    POST /rest/v1/rpc/terminal_sincronizar  { "p_eventos": [ {tipo, event_id, dados}, ... ] }
--
--  Cabeçalhos obrigatórios:
--    apikey: <publishable/anon key>      x-device-id: <ID do chip>      x-device-key: <chave do terminal>
--
--  Tipos de evento (p_tipo):
--    IDENTIFICAR_CARTAO   {uid, ocorrido_em, sessao_id?}
--    CONFIRMAR_OPERADOR   {sessao_id, confirmado: true|false, ocorrido_em}
--    SELECIONAR_PRODUTO   {sessao_id, produto_id, ocorrido_em}
--    SELECIONAR_PESO      {sessao_id, peso_nominal_kg, ocorrido_em}
--    SELECIONAR_EMBALAGEM {sessao_id, tipo_embalagem_id, ocorrido_em}
--    INICIAR_PESAGEM      {sessao_id, ocorrido_em}
--    CANCELAR_SESSAO      {sessao_id, motivo?, ocorrido_em}
--    CONFIRMAR_PESAGEM    {sessao_id, peso_lido, unidade, lido_em, confirmado_em, sequencia_terminal, leitura_estavel, pesagem_id?}
--    REGISTRAR_LEITURA    {sessao_id, peso_lido, unidade, lido_em, sequencia_terminal, leitura_estavel}   (fluxo em 2 passos)
--    REJEITAR_PESAGEM     {sessao_id, pesagem_id, motivo?, ocorrido_em}                                  (fluxo em 2 passos)
--    FINALIZAR_SESSAO     {sessao_id, ocorrido_em}
--    LOG                  {nivel, mensagem, ...}
--
--  IDEMPOTÊNCIA: todo evento tem event_id (UUID gerado na placa). O primeiro processamento
--  grava a resposta em terminal_eventos; qualquer reenvio (mesmo terminal, tipo e dados)
--  devolve a MESMA resposta com "replay": true — sem nova pesagem, sem novo movimento.
--  Reenviar com o mesmo event_id e dados diferentes → EVENT_ID_CONFLITO.
--
--  Recusa de negócio (cartão inválido, cancelamento bloqueado...) = HTTP 200 com ok=false
--  e é gravada (não adianta reenviar). Erro HTTP (4xx/5xx/timeout) = nada foi gravado:
--  a placa deve reenviar o MESMO evento (mesmo event_id e mesmo JSON).
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Helpers
-- -----------------------------------------------------------------------------
create or replace function public._resp(p_ok boolean, p_codigo text, p_mensagem text default null,
                                        p_extra jsonb default null)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('ok', p_ok, 'codigo', p_codigo, 'mensagem', p_mensagem) || coalesce(p_extra, '{}'::jsonb)
$$;

-- Recusa de negócio: aborta o processamento do evento (rollback parcial) e vira resposta ok=false gravada.
create or replace function public._recusar(p_codigo text, p_mensagem text, p_extra jsonb default null)
returns void language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'P0020', message = p_codigo, detail = coalesce(p_mensagem, p_codigo),
                        hint = coalesce(p_extra, '{}'::jsonb)::text;
end $$;

create or replace function public._uuid_ou_null(p text)
returns uuid language sql immutable set search_path = '' as $$
  select case when p ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
              then p::uuid end
$$;

create or replace function public._numero_ou_null(p text)
returns numeric language sql immutable set search_path = '' as $$
  select case when p ~ '^\s*[-+]?[0-9]+([.,][0-9]+)?\s*$' then replace(trim(p), ',', '.')::numeric end
$$;

-- Autenticação do dispositivo pelos cabeçalhos x-device-id / x-device-key (PostgREST expõe request.headers).
create or replace function public._terminal_autenticado()
returns public.terminais language plpgsql security definer set search_path = '' as $$
declare
  v_h    jsonb;
  v_dev  text;
  v_key  text;
  v_t    public.terminais;
  v_hash text;
begin
  begin
    v_h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_h := null;
  end;
  v_dev := upper(regexp_replace(coalesce(v_h ->> 'x-device-id', ''), '[^0-9A-Fa-f]', '', 'g'));
  v_key := v_h ->> 'x-device-key';
  if v_dev = '' or coalesce(v_key, '') = '' then
    raise exception 'TERMINAL_NAO_AUTENTICADO' using errcode = 'PT401', detail = 'Cabecalhos x-device-id/x-device-key ausentes';
  end if;

  select * into v_t from public.terminais where device_id = v_dev;
  select chave_hash into v_hash from public.terminal_credenciais where terminal_id = v_t.id;
  if v_t.id is null or v_hash is null
     or v_hash <> encode(extensions.digest(v_key, 'sha256'), 'hex') then
    raise exception 'TERMINAL_NAO_AUTENTICADO' using errcode = 'PT401', detail = 'Terminal desconhecido ou chave invalida';
  end if;
  if v_t.status <> 'ATIVO' then
    raise exception 'TERMINAL_INATIVO' using errcode = 'PT403', detail = 'Terminal ' || v_t.status::text;
  end if;
  return v_t;
end $$;

-- Sessão do terminal, travada para atualização (serializa eventos concorrentes da mesma sessão).
create or replace function public._sessao_travar(p_sessao text, p_terminal_id uuid)
returns public.sessoes_pesagem language plpgsql security definer set search_path = '' as $$
declare s public.sessoes_pesagem;
begin
  select * into s from public.sessoes_pesagem
   where id = public._uuid_ou_null(p_sessao) and terminal_id = p_terminal_id
   for update;
  if not found then
    perform public._recusar('SESSAO_NAO_ENCONTRADA', 'Sessao inexistente ou de outro terminal');
  end if;
  return s;
end $$;

-- Especificações produto/peso/embalagem utilizáveis num local (prefere a do local à global).
create or replace function public._especificacoes_disponiveis(p_local_id uuid)
returns setof public.produto_embalagens language sql stable security definer set search_path = '' as $$
  select pe.*
  from public.produto_embalagens pe
  join public.produtos        pr  on pr.id  = pe.produto_id         and pr.ativo and pr.disponivel_terminal
  join public.tipos_embalagem te  on te.id  = pe.tipo_embalagem_id  and te.ativo
  join public.itens_estoque   io  on io.id  = pe.item_origem_id     and io.ativo
  join public.itens_estoque   idt on idt.id = pe.item_destino_id    and idt.ativo
  join public.armazens        ao  on ao.id  = pe.armazem_origem_id  and ao.ativo
  join public.armazens        ad  on ad.id  = pe.armazem_destino_id and ad.ativo
  where pe.ativo and pe.disponivel_terminal
    and (pe.local_id is null or pe.local_id = p_local_id)
    and not (pe.local_id is null and exists (
          select 1 from public.produto_embalagens x
           where x.local_id = p_local_id and x.ativo and x.disponivel_terminal
             and x.produto_id = pe.produto_id and x.peso_nominal_kg = pe.peso_nominal_kg
             and x.tipo_embalagem_id = pe.tipo_embalagem_id))
$$;

-- Catálogo para os menus do LCD: produtos → pesos → embalagens (só o que tem regra de tolerância vigente).
create or replace function public._catalogo_terminal(p_local_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with ok as (
    select pe.id, pe.produto_id, pe.peso_nominal_kg, pe.tipo_embalagem_id,
           pr.nome_exibicao as pnome, pr.ordem as pordem, te.nome_exibicao as tnome, te.ordem as tordem,
           public._snapshot_especificacao(pe.id, now()) as snap
    from public._especificacoes_disponiveis(p_local_id) pe
    join public.produtos pr        on pr.id = pe.produto_id
    join public.tipos_embalagem te on te.id = pe.tipo_embalagem_id
  ), pesos as (
    select produto_id, pordem, pnome, peso_nominal_kg,
           jsonb_build_object('peso_kg', peso_nominal_kg,
             'embalagens', jsonb_agg(jsonb_build_object(
                 'id', tipo_embalagem_id, 'nome', tnome, 'especificacao_id', id,
                 'limite_min_kg', snap -> 'limite_min_kg', 'limite_max_kg', snap -> 'limite_max_kg')
               order by tordem, tnome)) as j
    from ok where snap is not null
    group by produto_id, pordem, pnome, peso_nominal_kg
  ), prods as (
    select pordem, pnome,
           jsonb_build_object('id', produto_id, 'nome', pnome, 'pesos', jsonb_agg(j order by peso_nominal_kg)) as j
    from pesos group by produto_id, pordem, pnome
  )
  select coalesce(jsonb_agg(j order by pordem, pnome), '[]'::jsonb) from prods
$$;

-- -----------------------------------------------------------------------------
--  Inserção de uma leitura (valida contra a tolerância CONGELADA na sessão)
-- -----------------------------------------------------------------------------
create or replace function public._pesagem_nova(s public.sessoes_pesagem, p_event_id uuid, d jsonb,
                                                p_origem public.evento_origem)
returns public.pesagens language plpgsql security definer set search_path = '' as $$
declare
  v_peso   numeric := public._numero_ou_null(d ->> 'peso_lido');
  v_un     text    := lower(coalesce(nullif(d ->> 'unidade', ''), 'kg'));
  v_kg     numeric;
  v_max    numeric := (public._config('peso_maximo_leitura_kg', '5000'::jsonb))::text::numeric;
  v_seq    integer;
  v_res    public.pesagem_resultado;
  p        public.pesagens;
begin
  if v_peso is null or v_un not in ('kg', 'g') then
    perform public._recusar('LEITURA_INVALIDA', 'Peso ou unidade invalidos',
                            jsonb_build_object('peso_lido', d -> 'peso_lido', 'unidade', d -> 'unidade'));
  end if;
  v_kg := round(case v_un when 'g' then v_peso / 1000.0 else v_peso end, 3);
  if abs(v_kg) > v_max then
    perform public._recusar('LEITURA_INVALIDA', 'Peso fora da faixa da balanca', jsonb_build_object('peso_kg', v_kg));
  end if;

  v_res := case when v_kg between s.limite_min_kg and s.limite_max_kg
                then 'DENTRO_TOLERANCIA' else 'FORA_TOLERANCIA' end::public.pesagem_resultado;
  select coalesce(max(sequencia), 0) + 1 into v_seq from public.pesagens where sessao_id = s.id;

  insert into public.pesagens
    (sessao_id, sequencia, sequencia_terminal, event_id, terminal_id, operador_id, produto_id,
     produto_embalagem_id, tipo_embalagem_id, peso_nominal_kg, peso_lido, unidade, peso_lido_kg,
     regra_tolerancia_id, tolerancia_modo, tolerancia_inferior, tolerancia_superior, limite_min_kg, limite_max_kg,
     resultado, status, contabilizada, leitura_estavel, lido_em, origem)
  values
    (s.id, v_seq, (public._numero_ou_null(d ->> 'sequencia_terminal'))::integer, p_event_id, s.terminal_id,
     s.operador_id, s.produto_id, s.produto_embalagem_id, s.tipo_embalagem_id, s.peso_nominal_kg, v_peso, v_un, v_kg,
     s.regra_tolerancia_id, s.tolerancia_modo, s.tolerancia_inferior, s.tolerancia_superior,
     s.limite_min_kg, s.limite_max_kg, v_res, v_res::text::public.pesagem_status, false,
     case lower(d ->> 'leitura_estavel') when 'true' then true when 'false' then false end,
     public._ts_dispositivo(d ->> 'lido_em'), p_origem)
  returning * into p;
  return p;
end $$;

create or replace function public._pesagem_json(p public.pesagens)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'pesagem_id', p.id, 'sequencia', p.sequencia, 'status', p.status, 'resultado', p.resultado,
    'contabilizada', p.contabilizada, 'peso_lido_kg', p.peso_lido_kg, 'peso_nominal_kg', p.peso_nominal_kg,
    'limite_min_kg', p.limite_min_kg, 'limite_max_kg', p.limite_max_kg, 'motivo', p.motivo)
$$;

-- -----------------------------------------------------------------------------
--  Handlers de evento (um por tipo). Recebem o terminal já autenticado.
-- -----------------------------------------------------------------------------
create or replace function public._ev_identificar_cartao(p_t public.terminais, p_event_id uuid, d jsonb,
                                                         p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid  text        := public.fn_normalizar_uid(d ->> 'uid');
  v_ts   timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  c      public.cartoes_rfid;
  vin    public.cartoes_rfid_vinculos;
  o      public.operadores;
  v_old  public.sessoes_pesagem;
  s      public.sessoes_pesagem;
  v_nome text;
begin
  if v_uid is null or v_uid !~ '^[0-9A-F]{8,20}$' then
    perform public._recusar('RFID_INVALIDO', 'UID de cartao invalido', jsonb_build_object('uid', d ->> 'uid'));
  end if;
  select * into c from public.cartoes_rfid where uid = v_uid;
  if not found then
    perform public._recusar('RFID_INVALIDO', 'Cartao nao cadastrado', jsonb_build_object('uid', v_uid));
  end if;
  if c.status <> 'ATIVO' then
    perform public._recusar('RFID_INATIVO', 'Cartao ' || c.status::text, jsonb_build_object('uid', v_uid));
  end if;
  select * into vin from public.cartoes_rfid_vinculos
   where cartao_id = c.id and inicio <= v_ts and (fim is null or fim > v_ts)
   order by inicio desc limit 1;
  if not found then
    perform public._recusar('RFID_SEM_OPERADOR', 'Cartao sem operador vinculado', jsonb_build_object('uid', v_uid));
  end if;
  select * into o from public.operadores where id = vin.operador_id;
  if not o.ativo then
    perform public._recusar('OPERADOR_INATIVO', 'Operador inativo', jsonb_build_object('uid', v_uid));
  end if;

  -- Sessão aberta neste terminal: pré-início é substituída; em pesagem bloqueia.
  select * into v_old from public.sessoes_pesagem
   where terminal_id = p_t.id and status not in ('FINALIZADA', 'CANCELADA') for update;
  if found then
    if v_old.status = 'PESAGEM_EM_ANDAMENTO' then
      perform public._recusar('TERMINAL_COM_SESSAO_EM_ANDAMENTO', 'Finalize a sessao aberta',
                              jsonb_build_object('sessao', public._sessao_json(v_old)));
    end if;
    update public.sessoes_pesagem
       set status = 'CANCELADA', cancelada_em = greatest(v_ts, identificado_em),
           motivo_encerramento = 'SUBSTITUIDA_POR_NOVA_IDENTIFICACAO', encerramento_origem = p_origem
     where id = v_old.id;
    perform public._auditar(p_origem, 'SESSAO_CANCELADA', 'sessoes_pesagem', v_old.id::text, p_t.id, v_old.operador_id,
                            v_old.id, null, p_event_id, jsonb_build_object('status', v_old.status),
                            jsonb_build_object('status', 'CANCELADA'),
                            jsonb_build_object('motivo', 'SUBSTITUIDA_POR_NOVA_IDENTIFICACAO'), v_ts);
  end if;

  -- Sessão aberta do mesmo operador em OUTRO terminal.
  select * into v_old from public.sessoes_pesagem
   where operador_id = o.id and status not in ('FINALIZADA', 'CANCELADA') for update;
  if found then
    if v_old.status = 'PESAGEM_EM_ANDAMENTO' then
      select nome into v_nome from public.terminais where id = v_old.terminal_id;
      perform public._recusar('OPERADOR_COM_SESSAO_EM_ANDAMENTO', 'Operador pesando em ' || coalesce(v_nome, '?'),
                              jsonb_build_object('sessao_id', v_old.id, 'terminal', v_nome));
    end if;
    update public.sessoes_pesagem
       set status = 'CANCELADA', cancelada_em = greatest(v_ts, identificado_em),
           motivo_encerramento = 'OPERADOR_IDENTIFICADO_EM_OUTRO_TERMINAL', encerramento_origem = p_origem
     where id = v_old.id;
    perform public._auditar(p_origem, 'SESSAO_CANCELADA', 'sessoes_pesagem', v_old.id::text, v_old.terminal_id,
                            v_old.operador_id, v_old.id, null, p_event_id, jsonb_build_object('status', v_old.status),
                            jsonb_build_object('status', 'CANCELADA'),
                            jsonb_build_object('motivo', 'OPERADOR_IDENTIFICADO_EM_OUTRO_TERMINAL'), v_ts);
  end if;

  insert into public.sessoes_pesagem
    (id, terminal_id, local_id, operador_id, cartao_id, cartao_uid, operador_nome, status,
     identificado_em, origem, evento_abertura_id)
  values
    (coalesce(public._uuid_ou_null(d ->> 'sessao_id'), gen_random_uuid()), p_t.id, p_t.local_id, o.id, c.id, c.uid,
     o.nome, 'OPERADOR_IDENTIFICADO', v_ts, p_origem, p_event_id)
  returning * into s;

  perform public._auditar(p_origem, 'RFID_IDENTIFICADO', 'sessoes_pesagem', s.id::text, p_t.id, o.id, s.id, null,
                          p_event_id, null, jsonb_build_object('status', s.status),
                          jsonb_build_object('uid', c.uid, 'operador', o.nome), v_ts);

  return public._resp(true, 'OPERADOR_IDENTIFICADO', o.nome_exibicao,
           jsonb_build_object('sessao_id', s.id, 'sessao', public._sessao_json(s),
                              'catalogo', public._catalogo_terminal(p_t.local_id)));
end $$;

create or replace function public._ev_confirmar_operador(p_t public.terminais, p_event_id uuid, d jsonb,
                                                         p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  s    public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
begin
  if s.status <> 'OPERADOR_IDENTIFICADO' then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  if lower(coalesce(d ->> 'confirmado', '')) in ('true', '1', 'sim') then
    update public.sessoes_pesagem set status = 'SELECIONANDO_PRODUTO', operador_confirmado_em = v_ts
     where id = s.id returning * into s;
    perform public._auditar(p_origem, 'OPERADOR_CONFIRMADO', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                            s.id, null, p_event_id, jsonb_build_object('status', 'OPERADOR_IDENTIFICADO'),
                            jsonb_build_object('status', s.status), null, v_ts);
    return public._resp(true, 'OPERADOR_CONFIRMADO', 'Selecione produto',
                        jsonb_build_object('sessao_id', s.id, 'sessao', public._sessao_json(s)));
  end if;
  update public.sessoes_pesagem
     set status = 'CANCELADA', cancelada_em = v_ts, motivo_encerramento = 'OPERADOR_NAO_CONFIRMOU',
         encerramento_origem = p_origem
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'OPERADOR_NAO_CONFIRMOU', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, jsonb_build_object('status', 'OPERADOR_IDENTIFICADO'),
                          jsonb_build_object('status', s.status), null, v_ts);
  return public._resp(true, 'SESSAO_CANCELADA', 'Identidade negada', jsonb_build_object('sessao_id', s.id));
end $$;

create or replace function public._ev_selecionar_produto(p_t public.terminais, p_event_id uuid, d jsonb,
                                                         p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts   timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  v_prod uuid        := public._uuid_ou_null(d ->> 'produto_id');
  s      public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  v_ant  jsonb;
  v_pesos jsonb;
begin
  if s.status not in ('SELECIONANDO_PRODUTO', 'SELECIONANDO_PESO', 'SELECIONANDO_EMBALAGEM', 'PRONTO_PARA_INICIAR') then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  select jsonb_agg(distinct peso_nominal_kg) into v_pesos
    from public._especificacoes_disponiveis(p_t.local_id) e
   where e.produto_id = v_prod and public._snapshot_especificacao(e.id, now()) is not null;
  if v_pesos is null then
    perform public._recusar('PRODUTO_INDISPONIVEL', 'Produto indisponivel', jsonb_build_object('produto_id', d ->> 'produto_id'));
  end if;
  v_ant := jsonb_build_object('status', s.status, 'produto_id', s.produto_id);
  update public.sessoes_pesagem
     set status = 'SELECIONANDO_PESO', produto_id = v_prod, produto_selecionado_em = v_ts,
         peso_nominal_kg = null, peso_selecionado_em = null,
         tipo_embalagem_id = null, produto_embalagem_id = null, embalagem_selecionada_em = null
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'PRODUTO_SELECIONADO', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, v_ant,
                          jsonb_build_object('status', s.status, 'produto_id', s.produto_id), null, v_ts);
  return public._resp(true, 'PRODUTO_SELECIONADO', 'Selecione o peso',
           jsonb_build_object('sessao_id', s.id, 'pesos',
             (select jsonb_agg(x order by x::text::numeric) from jsonb_array_elements(v_pesos) x)));
end $$;

create or replace function public._ev_selecionar_peso(p_t public.terminais, p_event_id uuid, d jsonb,
                                                      p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts   timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  v_peso numeric     := public._numero_ou_null(d ->> 'peso_nominal_kg');
  s      public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  v_ant  jsonb;
  v_emb  jsonb;
begin
  if s.status not in ('SELECIONANDO_PESO', 'SELECIONANDO_EMBALAGEM', 'PRONTO_PARA_INICIAR') or s.produto_id is null then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  select jsonb_agg(jsonb_build_object('id', te.id, 'nome', te.nome_exibicao, 'especificacao_id', e.id,
                                      'limite_min_kg', sn -> 'limite_min_kg', 'limite_max_kg', sn -> 'limite_max_kg')
                   order by te.ordem, te.nome_exibicao)
    into v_emb
    from public._especificacoes_disponiveis(p_t.local_id) e
    join public.tipos_embalagem te on te.id = e.tipo_embalagem_id
    cross join lateral public._snapshot_especificacao(e.id, now()) sn
   where e.produto_id = s.produto_id and e.peso_nominal_kg = v_peso and sn is not null;
  if v_emb is null then
    perform public._recusar('PESO_INDISPONIVEL', 'Peso indisponivel', jsonb_build_object('peso_nominal_kg', d -> 'peso_nominal_kg'));
  end if;
  v_ant := jsonb_build_object('status', s.status, 'peso_nominal_kg', s.peso_nominal_kg);
  update public.sessoes_pesagem
     set status = 'SELECIONANDO_EMBALAGEM', peso_nominal_kg = v_peso, peso_selecionado_em = v_ts,
         tipo_embalagem_id = null, produto_embalagem_id = null, embalagem_selecionada_em = null
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'PESO_SELECIONADO', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, v_ant,
                          jsonb_build_object('status', s.status, 'peso_nominal_kg', s.peso_nominal_kg), null, v_ts);
  return public._resp(true, 'PESO_SELECIONADO', 'Selecione embalagem',
                      jsonb_build_object('sessao_id', s.id, 'embalagens', v_emb));
end $$;

create or replace function public._ev_selecionar_embalagem(p_t public.terminais, p_event_id uuid, d jsonb,
                                                           p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts   timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  v_tipo uuid        := public._uuid_ou_null(d ->> 'tipo_embalagem_id');
  s      public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  v_pe   uuid;
  v_snap jsonb;
  v_ant  jsonb;
begin
  if s.status not in ('SELECIONANDO_EMBALAGEM', 'PRONTO_PARA_INICIAR') or s.peso_nominal_kg is null then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  select e.id into v_pe from public._especificacoes_disponiveis(p_t.local_id) e
   where e.produto_id = s.produto_id and e.peso_nominal_kg = s.peso_nominal_kg and e.tipo_embalagem_id = v_tipo;
  if v_pe is null then
    perform public._recusar('EMBALAGEM_INDISPONIVEL', 'Embalagem indisponivel',
                            jsonb_build_object('tipo_embalagem_id', d ->> 'tipo_embalagem_id'));
  end if;
  v_snap := public._snapshot_especificacao(v_pe, v_ts);
  if v_snap is null then
    perform public._recusar('SEM_REGRA_TOLERANCIA', 'Sem tolerancia cadastrada', jsonb_build_object('especificacao_id', v_pe));
  end if;
  v_ant := jsonb_build_object('status', s.status, 'tipo_embalagem_id', s.tipo_embalagem_id);
  update public.sessoes_pesagem
     set status = 'PRONTO_PARA_INICIAR', tipo_embalagem_id = v_tipo, produto_embalagem_id = v_pe,
         embalagem_selecionada_em = v_ts
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'EMBALAGEM_SELECIONADA', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, v_ant,
                          jsonb_build_object('status', s.status, 'tipo_embalagem_id', v_tipo, 'produto_embalagem_id', v_pe),
                          null, v_ts);
  return public._resp(true, 'PRONTO_PARA_INICIAR', 'Iniciar pesagem?',
           jsonb_build_object('sessao_id', s.id,
                              'previa_tolerancia', jsonb_build_object(
                                 'limite_min_kg', v_snap -> 'limite_min_kg', 'limite_max_kg', v_snap -> 'limite_max_kg',
                                 'modo', v_snap -> 'tolerancia_modo')));
end $$;

create or replace function public._ev_iniciar_pesagem(p_t public.terminais, p_event_id uuid, d jsonb,
                                                      p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts   timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  s      public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  v_snap jsonb;
begin
  if s.status <> 'PRONTO_PARA_INICIAR' then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  if not exists (select 1 from public._especificacoes_disponiveis(p_t.local_id) e where e.id = s.produto_embalagem_id) then
    perform public._recusar('ESPECIFICACAO_INDISPONIVEL', 'Cadastro alterado', jsonb_build_object('sessao_id', s.id));
  end if;
  -- CONGELA a regra vigente neste instante (alterações futuras não afetam esta sessão)
  v_snap := public._snapshot_especificacao(s.produto_embalagem_id, v_ts);
  if v_snap is null then
    perform public._recusar('SEM_REGRA_TOLERANCIA', 'Sem tolerancia cadastrada', jsonb_build_object('sessao_id', s.id));
  end if;
  update public.sessoes_pesagem set
    status               = 'PESAGEM_EM_ANDAMENTO',
    iniciada_em          = v_ts,
    regra_tolerancia_id  = (v_snap ->> 'regra_tolerancia_id')::uuid,
    tolerancia_modo      = (v_snap ->> 'tolerancia_modo')::public.tolerancia_modo,
    tolerancia_inferior  = (v_snap ->> 'tolerancia_inferior')::numeric,
    tolerancia_superior  = (v_snap ->> 'tolerancia_superior')::numeric,
    limite_min_kg        = (v_snap ->> 'limite_min_kg')::numeric,
    limite_max_kg        = (v_snap ->> 'limite_max_kg')::numeric,
    item_origem_id       = (v_snap ->> 'item_origem_id')::uuid,
    armazem_origem_id    = (v_snap ->> 'armazem_origem_id')::uuid,
    item_destino_id      = (v_snap ->> 'item_destino_id')::uuid,
    armazem_destino_id   = (v_snap ->> 'armazem_destino_id')::uuid,
    unidades_por_pesagem = (v_snap ->> 'unidades_por_pesagem')::numeric,
    base_consumo         = (v_snap ->> 'base_consumo')::public.base_consumo,
    snapshot             = v_snap
  where id = s.id returning * into s;
  perform public._auditar(p_origem, 'PESAGEM_INICIADA', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, jsonb_build_object('status', 'PRONTO_PARA_INICIAR'),
                          jsonb_build_object('status', s.status), jsonb_build_object('snapshot', v_snap), v_ts);
  return public._resp(true, 'PESAGEM_EM_ANDAMENTO', 'Pesagem iniciada',
                      jsonb_build_object('sessao_id', s.id, 'sessao', public._sessao_json(s)));
end $$;

create or replace function public._ev_cancelar_sessao(p_t public.terminais, p_event_id uuid, d jsonb,
                                                      p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  s    public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  v_st public.sessao_status := s.status;
begin
  if s.status = 'PESAGEM_EM_ANDAMENTO' then
    -- REGRA 10: depois de INICIAR, CANCELAR é bloqueado (a tentativa fica registrada pelo inbox + auditoria)
    perform public._recusar('CANCELAMENTO_BLOQUEADO', 'Use FINALIZAR', jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  if s.status in ('FINALIZADA', 'CANCELADA') then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  update public.sessoes_pesagem
     set status = 'CANCELADA', cancelada_em = greatest(v_ts, identificado_em),
         motivo_encerramento = coalesce(nullif(d ->> 'motivo', ''), 'CANCELADO_PELO_OPERADOR'),
         encerramento_origem = p_origem
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'SESSAO_CANCELADA', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id,
                          s.id, null, p_event_id, jsonb_build_object('status', v_st),
                          jsonb_build_object('status', s.status), jsonb_build_object('motivo', s.motivo_encerramento), v_ts);
  return public._resp(true, 'SESSAO_CANCELADA', 'Sessao cancelada', jsonb_build_object('sessao_id', s.id));
end $$;

create or replace function public._exigir_sessao_em_pesagem(s public.sessoes_pesagem, p_origem public.evento_origem)
returns void language plpgsql security definer set search_path = '' as $$
declare v_ativo boolean;
begin
  if s.status <> 'PESAGEM_EM_ANDAMENTO' then
    perform public._recusar('SESSAO_NAO_EM_PESAGEM', 'Sessao ' || s.status::text,
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  -- operador válido. Eventos sincronizados depois (offline) são aceitos: o operador era válido ao iniciar.
  select ativo into v_ativo from public.operadores where id = s.operador_id;
  if not v_ativo and p_origem = 'TERMINAL' then
    perform public._recusar('OPERADOR_INATIVO', 'Operador inativo', jsonb_build_object('sessao_id', s.id));
  end if;
end $$;

create or replace function public._ev_registrar_leitura(p_t public.terminais, p_event_id uuid, d jsonb,
                                                        p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  p public.pesagens;
begin
  perform public._exigir_sessao_em_pesagem(s, p_origem);
  p := public._pesagem_nova(s, p_event_id, d, p_origem);
  s := public._sessao_recalcular_totais(s.id);
  perform public._auditar(p_origem, 'LEITURA_REGISTRADA', 'pesagens', p.id::text, p_t.id, s.operador_id, s.id, p.id,
                          p_event_id, null, public._pesagem_json(p), null, p.lido_em);
  return public._resp(true, p.status::text, case p.resultado when 'DENTRO_TOLERANCIA' then 'Confirme' else 'Fora tolerancia' end,
           jsonb_build_object('sessao_id', s.id, 'pesagem_id', p.id, 'pesagem', public._pesagem_json(p),
                              'totais', public._sessao_json(s) -> 'totais'));
end $$;

-- ★ CONFIRMAR_PESAGEM — operação transacional principal (requisito 28)
create or replace function public._ev_confirmar_pesagem(p_t public.terminais, p_event_id uuid, d jsonb,
                                                        p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s        public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);   -- 1,2 sessão travada
  p        public.pesagens;
  v_pid    uuid := public._uuid_ou_null(d ->> 'pesagem_id');
  v_conf   timestamptz := public._ts_dispositivo(coalesce(d ->> 'confirmado_em', d ->> 'ocorrido_em'));
  v_codigo text;
  v_msg    text;
  v_mov    jsonb;
  v_acao   text;
begin
  perform public._exigir_sessao_em_pesagem(s, p_origem);                                    -- 2,3 estado + operador

  if v_pid is not null then                                                                  -- fluxo em 2 passos
    select * into p from public.pesagens where id = v_pid and sessao_id = s.id for update;
    if not found then
      perform public._recusar('PESAGEM_NAO_ENCONTRADA', 'Pesagem inexistente', jsonb_build_object('pesagem_id', v_pid));
    end if;
    if p.status not in ('DENTRO_TOLERANCIA', 'FORA_TOLERANCIA')
       or (p.status = 'FORA_TOLERANCIA' and p.confirmado_em is not null) then
      perform public._recusar('PESAGEM_JA_FINALIZADA', 'Pesagem ' || p.status::text,
                              jsonb_build_object('pesagem', public._pesagem_json(p)));
    end if;
  else                                                                                       -- fluxo direto (ESP32)
    p := public._pesagem_nova(s, p_event_id, d, p_origem);                                   -- 6,7 registra + valida
  end if;

  if p.resultado = 'DENTRO_TOLERANCIA' then
    begin                                                                                    -- subtransação
      update public.pesagens
         set status = 'CONFIRMADA', contabilizada = true, confirmado_em = v_conf,
             confirmado_por_operador_id = s.operador_id,
             evento_confirmacao_id = case when v_pid is not null then p_event_id end
       where id = p.id returning * into p;
      v_mov := public._estoque_movimentar_pesagem(p.id, p_origem);                           -- 9,10 estoque
      v_codigo := 'PESAGEM_CONFIRMADA'; v_msg := 'Pesagem OK'; v_acao := 'PESAGEM_CONFIRMADA';
    exception when sqlstate 'P0010' then                                                     -- sem saldo de origem
      update public.pesagens
         set status = 'REJEITADA', motivo = 'ESTOQUE_INSUFICIENTE', confirmado_em = v_conf,
             confirmado_por_operador_id = s.operador_id,
             evento_confirmacao_id = case when v_pid is not null then p_event_id end
       where id = p.id returning * into p;
      v_codigo := 'ESTOQUE_INSUFICIENTE'; v_msg := 'Sem estoque origem'; v_acao := 'PESAGEM_REJEITADA_ESTOQUE';
    end;
  else
    -- REGRA 7: fora da tolerância nunca contabiliza nem movimenta estoque; fica registrada.
    update public.pesagens
       set confirmado_em = v_conf, confirmado_por_operador_id = s.operador_id,
           evento_confirmacao_id = case when v_pid is not null then p_event_id end
     where id = p.id returning * into p;
    v_codigo := 'FORA_TOLERANCIA'; v_msg := 'Fora tolerancia'; v_acao := 'PESAGEM_FORA_TOLERANCIA';
  end if;

  s := public._sessao_recalcular_totais(s.id);                                               -- 11 totais
  perform public._auditar(p_origem, v_acao, 'pesagens', p.id::text, p_t.id, s.operador_id, s.id, p.id, p_event_id,
                          null, public._pesagem_json(p), jsonb_build_object('estoque', v_mov), v_conf);  -- 12
  return public._resp(true, v_codigo, v_msg,
           jsonb_build_object('sessao_id', s.id, 'pesagem_id', p.id, 'pesagem', public._pesagem_json(p),
                              'estoque', v_mov, 'totais', public._sessao_json(s) -> 'totais'));
end $$;

create or replace function public._ev_rejeitar_pesagem(p_t public.terminais, p_event_id uuid, d jsonb,
                                                       p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  s     public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
  p     public.pesagens;
  v_ts  timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
begin
  perform public._exigir_sessao_em_pesagem(s, p_origem);
  select * into p from public.pesagens where id = public._uuid_ou_null(d ->> 'pesagem_id') and sessao_id = s.id for update;
  if not found then
    perform public._recusar('PESAGEM_NAO_ENCONTRADA', 'Pesagem inexistente', jsonb_build_object('pesagem_id', d ->> 'pesagem_id'));
  end if;
  if p.status not in ('REGISTRADA', 'DENTRO_TOLERANCIA', 'FORA_TOLERANCIA')
     or (p.status = 'FORA_TOLERANCIA' and p.confirmado_em is not null) then
    perform public._recusar('PESAGEM_JA_FINALIZADA', 'Pesagem ' || p.status::text,
                            jsonb_build_object('pesagem', public._pesagem_json(p)));
  end if;
  update public.pesagens
     set status = 'REJEITADA', motivo = coalesce(nullif(d ->> 'motivo', ''), 'REJEITADA_PELO_OPERADOR'),
         confirmado_em = v_ts, confirmado_por_operador_id = s.operador_id, evento_confirmacao_id = p_event_id
   where id = p.id returning * into p;
  s := public._sessao_recalcular_totais(s.id);
  perform public._auditar(p_origem, 'PESAGEM_REJEITADA', 'pesagens', p.id::text, p_t.id, s.operador_id, s.id, p.id,
                          p_event_id, null, public._pesagem_json(p), null, v_ts);
  return public._resp(true, 'PESAGEM_REJEITADA', 'Pesagem rejeitada',
           jsonb_build_object('sessao_id', s.id, 'pesagem_id', p.id, 'pesagem', public._pesagem_json(p),
                              'totais', public._sessao_json(s) -> 'totais'));
end $$;

create or replace function public._ev_finalizar_sessao(p_t public.terminais, p_event_id uuid, d jsonb,
                                                       p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ts timestamptz := public._ts_dispositivo(d ->> 'ocorrido_em');
  s    public.sessoes_pesagem := public._sessao_travar(d ->> 'sessao_id', p_t.id);
begin
  if s.status = 'FINALIZADA' then
    perform public._recusar('SESSAO_JA_FINALIZADA', 'Sessao ja finalizada',
                            jsonb_build_object('sessao_id', s.id, 'sessao', public._sessao_json(s)));
  end if;
  if s.status <> 'PESAGEM_EM_ANDAMENTO' then
    perform public._recusar('ESTADO_INVALIDO', 'Sessao em ' || s.status::text || ' (use CANCELAR)',
                            jsonb_build_object('sessao_id', s.id, 'status', s.status));
  end if;
  -- leituras pendentes (fluxo em 2 passos) nunca são contabilizadas
  update public.pesagens set status = 'CANCELADA', motivo = 'SESSAO_FINALIZADA'
   where sessao_id = s.id and status in ('REGISTRADA', 'DENTRO_TOLERANCIA');
  perform public._sessao_recalcular_totais(s.id);
  update public.sessoes_pesagem
     set status = 'FINALIZADA', finalizada_em = greatest(v_ts, iniciada_em),
         motivo_encerramento = 'FINALIZADA_PELO_OPERADOR', encerramento_origem = p_origem
   where id = s.id returning * into s;
  perform public._auditar(p_origem, 'SESSAO_FINALIZADA', 'sessoes_pesagem', s.id::text, p_t.id, s.operador_id, s.id,
                          null, p_event_id, jsonb_build_object('status', 'PESAGEM_EM_ANDAMENTO'),
                          jsonb_build_object('status', s.status), public._sessao_json(s) -> 'totais', v_ts);
  return public._resp(true, 'SESSAO_FINALIZADA', 'Sessao finalizada',
                      jsonb_build_object('sessao_id', s.id, 'sessao', public._sessao_json(s)));
end $$;

create or replace function public._ev_log(p_t public.terminais, p_event_id uuid, d jsonb, p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public._auditar(p_origem, 'TERMINAL_LOG', 'terminais', p_t.id::text, p_t.id, null,
                          public._uuid_ou_null(d ->> 'sessao_id'), null, p_event_id, null, null, d,
                          public._ts_dispositivo(d ->> 'ocorrido_em'));
  return public._resp(true, 'LOG_REGISTRADO', null);
end $$;

-- -----------------------------------------------------------------------------
--  Processador idempotente (núcleo comum de online e sync)
-- -----------------------------------------------------------------------------
create or replace function public._terminal_processar(p_t public.terminais, p_tipo text, p_event_id uuid,
                                                      p_dados jsonb, p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_tipo  text  := upper(coalesce(p_tipo, ''));
  d       jsonb := coalesce(p_dados, '{}'::jsonb);
  v_hash  text;
  v_prev  public.terminal_eventos;
  v_resp  jsonb;
  v_cod   text;
  v_det   text;
  v_hint  text;
begin
  if p_event_id is null then
    return public._resp(false, 'EVENT_ID_OBRIGATORIO', 'event_id ausente', jsonb_build_object('retry', false));
  end if;
  if jsonb_typeof(d) <> 'object' then
    return public._resp(false, 'EVENTO_MALFORMADO', 'dados deve ser objeto', jsonb_build_object('event_id', p_event_id, 'retry', false));
  end if;
  v_hash := md5(d::text);

  -- serializa reenvios simultâneos do mesmo event_id (retry agressivo da placa)
  perform pg_advisory_xact_lock(hashtextextended('terminal_evento:' || p_event_id::text, 0));

  select * into v_prev from public.terminal_eventos where event_id = p_event_id;
  if found then
    if v_prev.terminal_id <> p_t.id or v_prev.tipo <> v_tipo or v_prev.dados_hash <> v_hash then
      perform public._auditar(p_origem, 'EVENT_ID_CONFLITO', 'terminal_eventos', p_event_id::text, p_t.id,
                              null, null, null, p_event_id, null, null,
                              jsonb_build_object('tipo', v_tipo, 'dados', d, 'original_tipo', v_prev.tipo));
      return public._resp(false, 'EVENT_ID_CONFLITO', 'event_id reutilizado',
                          jsonb_build_object('event_id', p_event_id, 'retry', false));
    end if;
    return v_prev.resposta || jsonb_build_object('replay', true);
  end if;

  begin
    v_resp := case v_tipo
      when 'IDENTIFICAR_CARTAO'   then public._ev_identificar_cartao  (p_t, p_event_id, d, p_origem)
      when 'CONFIRMAR_OPERADOR'   then public._ev_confirmar_operador  (p_t, p_event_id, d, p_origem)
      when 'SELECIONAR_PRODUTO'   then public._ev_selecionar_produto  (p_t, p_event_id, d, p_origem)
      when 'SELECIONAR_PESO'      then public._ev_selecionar_peso     (p_t, p_event_id, d, p_origem)
      when 'SELECIONAR_EMBALAGEM' then public._ev_selecionar_embalagem(p_t, p_event_id, d, p_origem)
      when 'INICIAR_PESAGEM'      then public._ev_iniciar_pesagem     (p_t, p_event_id, d, p_origem)
      when 'CANCELAR_SESSAO'      then public._ev_cancelar_sessao     (p_t, p_event_id, d, p_origem)
      when 'REGISTRAR_LEITURA'    then public._ev_registrar_leitura   (p_t, p_event_id, d, p_origem)
      when 'CONFIRMAR_PESAGEM'    then public._ev_confirmar_pesagem   (p_t, p_event_id, d, p_origem)
      when 'REJEITAR_PESAGEM'     then public._ev_rejeitar_pesagem    (p_t, p_event_id, d, p_origem)
      when 'FINALIZAR_SESSAO'     then public._ev_finalizar_sessao    (p_t, p_event_id, d, p_origem)
      when 'LOG'                  then public._ev_log                 (p_t, p_event_id, d, p_origem)
    end;
    if v_resp is null then
      perform public._recusar('TIPO_EVENTO_INVALIDO', 'Tipo desconhecido: ' || v_tipo);
    end if;
  exception when sqlstate 'P0020' then
    -- recusa de negócio: o que o handler fez foi desfeito; registra a recusa
    get stacked diagnostics v_cod = message_text, v_det = pg_exception_detail, v_hint = pg_exception_hint;
    v_resp := public._resp(false, v_cod, v_det, nullif(v_hint, '')::jsonb);
    perform public._auditar(p_origem, v_cod, 'terminal_eventos', p_event_id::text, p_t.id, null,
                            public._uuid_ou_null(coalesce(v_resp ->> 'sessao_id', d ->> 'sessao_id')), null,
                            p_event_id, null, null, jsonb_build_object('tipo', v_tipo, 'dados', d, 'mensagem', v_det),
                            public._ts_dispositivo(coalesce(d ->> 'ocorrido_em', d ->> 'lido_em')));
  end;

  v_resp := v_resp || jsonb_build_object('event_id', p_event_id, 'tipo', v_tipo, 'replay', false, 'retry', false);

  insert into public.terminal_eventos
    (event_id, terminal_id, tipo, dados, dados_hash, ocorrido_em, origem, ok, codigo, resposta, sessao_id, pesagem_id)
  values
    (p_event_id, p_t.id, v_tipo, d, v_hash,
     public._ts_dispositivo(coalesce(d ->> 'ocorrido_em', d ->> 'confirmado_em', d ->> 'lido_em')),
     p_origem, coalesce((v_resp ->> 'ok')::boolean, false), v_resp ->> 'codigo', v_resp,
     public._uuid_ou_null(coalesce(v_resp ->> 'sessao_id', d ->> 'sessao_id')),
     public._uuid_ou_null(v_resp ->> 'pesagem_id'));
  return v_resp;
end $$;

-- -----------------------------------------------------------------------------
--  RPCs PÚBLICAS DO TERMINAL
-- -----------------------------------------------------------------------------
create or replace function public.terminal_evento(p_tipo text, p_event_id uuid, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_t public.terminais := public._terminal_autenticado();
begin
  return public._terminal_processar(v_t, p_tipo, p_event_id, p_dados, 'TERMINAL');
end $$;
comment on function public.terminal_evento(text, uuid, jsonb) is
  'Evento online do terminal (idempotente por event_id). Ver cabeçalho da migration 03 para os tipos.';

create or replace function public.terminal_sincronizar(p_eventos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_t     public.terminais := public._terminal_autenticado();
  v_max   integer := (public._config('sync_lote_max', '50'::jsonb))::text::integer;
  e       jsonb;
  r       jsonb;
  v_out   jsonb := '[]'::jsonb;
  v_parou boolean := false;
  v_n     integer := 0;
begin
  if jsonb_typeof(p_eventos) <> 'array' then
    raise exception 'p_eventos deve ser um array' using errcode = 'PT400';
  end if;
  if jsonb_array_length(p_eventos) > v_max then
    raise exception 'Lote maior que % eventos', v_max using errcode = 'PT413';
  end if;

  for e in select value from jsonb_array_elements(p_eventos) with ordinality order by ordinality loop
    if v_parou then
      -- preserva a ORDEM: após um erro temporário, o restante não é processado agora
      v_out := v_out || jsonb_build_array(public._resp(false, 'NAO_PROCESSADO', 'Reenviar',
                                         jsonb_build_object('event_id', e ->> 'event_id', 'retry', true)));
      continue;
    end if;
    if public._uuid_ou_null(e ->> 'event_id') is null then
      v_out := v_out || jsonb_build_array(public._resp(false, 'EVENTO_MALFORMADO', 'event_id invalido',
                                         jsonb_build_object('event_id', e ->> 'event_id', 'retry', false)));
      continue;
    end if;
    begin
      r := public._terminal_processar(v_t, e ->> 'tipo', (e ->> 'event_id')::uuid, e -> 'dados', 'TERMINAL_SYNC');
      v_n := v_n + 1;
    exception when others then
      r := public._resp(false, 'ERRO_TEMPORARIO', sqlerrm, jsonb_build_object('event_id', e ->> 'event_id', 'retry', true));
      v_parou := true;
    end;
    v_out := v_out || jsonb_build_array(r);
  end loop;

  update public.terminais set ultimo_sync_em = now(), ultimo_heartbeat = now() where id = v_t.id;
  return jsonb_build_object('ok', true, 'processados', v_n, 'resultados', v_out, 'server_time', now());
end $$;

create or replace function public.terminal_heartbeat(p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_t  public.terminais := public._terminal_autenticado();
  d    jsonb := coalesce(p_dados, '{}'::jsonb);
  s    public.sessoes_pesagem;
  v_l  public.locais;
begin
  update public.terminais set
    ultimo_heartbeat  = now(),
    firmware_versao   = coalesce(left(d ->> 'firmware_versao', 40), firmware_versao),
    estado_reportado  = coalesce(left(d ->> 'estado', 40), estado_reportado),
    eventos_pendentes = coalesce((public._numero_ou_null(d ->> 'eventos_pendentes'))::integer, eventos_pendentes),
    ultimo_ip         = coalesce(left(d ->> 'ip', 45), ultimo_ip),
    ultimo_rssi       = coalesce((public._numero_ou_null(d ->> 'rssi'))::integer, ultimo_rssi)
  where id = v_t.id;
  select * into v_l from public.locais where id = v_t.local_id;
  select * into s from public.sessoes_pesagem
   where terminal_id = v_t.id and status not in ('FINALIZADA', 'CANCELADA');
  return jsonb_build_object(
    'ok', true,
    'server_time', now(),
    'terminal', jsonb_build_object('id', v_t.id, 'nome', v_t.nome, 'device_id', v_t.device_id,
                                   'local', v_l.nome, 'config', v_t.config),
    'config', jsonb_build_object(
       'heartbeat_intervalo_seg', public._config('heartbeat_intervalo_seg', '30'::jsonb),
       'sync_lote_max',           public._config('sync_lote_max', '50'::jsonb)),
    'sessao_aberta', case when s.id is null then null else public._sessao_json(s) end);
end $$;

create or replace function public.terminal_catalogo()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_t public.terminais := public._terminal_autenticado();
  v_c jsonb := public._catalogo_terminal(v_t.local_id);
begin
  return jsonb_build_object('ok', true, 'versao', md5(v_c::text), 'produtos', v_c);
end $$;
