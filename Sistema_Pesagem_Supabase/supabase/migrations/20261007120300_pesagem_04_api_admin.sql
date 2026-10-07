-- =============================================================================
--  TERMINAL DE PESAGEM — 04 · API ADMINISTRATIVA (APP/WEB, usuários autenticados)
-- -----------------------------------------------------------------------------
--  Cadastros simples (produtos, embalagens, tolerâncias...) são feitos direto nas
--  tabelas pelo APP/WEB, protegidos por RLS (migration 05). Operações críticas
--  passam por estas RPCs: credencial de terminal, vínculo de cartão, lançamentos
--  manuais de estoque e encerramento forçado de sessão.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Papel do usuário logado (usado nas policies)
-- -----------------------------------------------------------------------------
create or replace function public.fn_papel_atual()
returns public.papel_usuario language sql stable security definer set search_path = '' as $$
  select papel from public.perfis where id = auth.uid() and ativo
$$;

create or replace function public.fn_tem_papel(variadic p_papeis public.papel_usuario[])
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(public.fn_papel_atual() = any (p_papeis), false)
$$;

create or replace function public.fn_operador_atual()
returns uuid language sql stable security definer set search_path = '' as $$
  select operador_id from public.perfis where id = auth.uid() and ativo
$$;

create or replace function public._exigir_papel(variadic p_papeis public.papel_usuario[])
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.fn_tem_papel(variadic p_papeis) then
    raise exception 'Permissao negada' using errcode = '42501',
      detail = 'Requer papel: ' || array_to_string(p_papeis, ', ');
  end if;
end $$;

-- -----------------------------------------------------------------------------
--  Terminais
-- -----------------------------------------------------------------------------
-- Cadastra (ou reaproveita) o terminal e devolve a chave em texto UMA ÚNICA VEZ.
create or replace function public.admin_terminal_registrar(
  p_device_id text, p_nome text, p_local_id uuid default null, p_localizacao text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_t     public.terminais;
  v_chave text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  perform public._exigir_papel('ADMIN');
  insert into public.terminais (device_id, nome, local_id, localizacao)
  values (p_device_id, p_nome, p_local_id, p_localizacao)
  on conflict (device_id) do update
     set nome = excluded.nome, local_id = excluded.local_id, localizacao = excluded.localizacao
  returning * into v_t;

  insert into public.terminal_credenciais (terminal_id, chave_hash, gerada_por)
  values (v_t.id, encode(extensions.digest(v_chave, 'sha256'), 'hex'), auth.uid())
  on conflict (terminal_id) do update
     set chave_hash = excluded.chave_hash, gerada_em = now(), gerada_por = excluded.gerada_por;

  perform public._auditar('APP_WEB', 'TERMINAL_CHAVE_GERADA', 'terminais', v_t.id::text, v_t.id);
  return jsonb_build_object('terminal_id', v_t.id, 'device_id', v_t.device_id, 'nome', v_t.nome,
                            'chave', v_chave,
                            'aviso', 'Guarde a chave agora: ela não pode ser consultada depois. Gerar outra invalida a anterior.');
end $$;

create or replace function public.admin_terminal_alterar_status(p_terminal_id uuid, p_status public.terminal_status)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir_papel('ADMIN');
  update public.terminais set status = p_status where id = p_terminal_id;
  if not found then raise exception 'Terminal inexistente' using errcode = 'P0002'; end if;
end $$;

-- -----------------------------------------------------------------------------
--  Cartões RFID (com histórico de vínculo)
-- -----------------------------------------------------------------------------
create or replace function public.admin_cartao_vincular(p_uid text, p_operador_id uuid,
                                                        p_motivo text default null, p_descricao text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid  text := public.fn_normalizar_uid(p_uid);
  c      public.cartoes_rfid;
  v_ant  public.cartoes_rfid_vinculos;
  v_novo public.cartoes_rfid_vinculos;
begin
  perform public._exigir_papel('ADMIN', 'SUPERVISOR');
  if v_uid is null then raise exception 'UID invalido' using errcode = '22023'; end if;
  if not exists (select 1 from public.operadores where id = p_operador_id) then
    raise exception 'Operador inexistente' using errcode = 'P0002';
  end if;

  insert into public.cartoes_rfid (uid, descricao) values (v_uid, p_descricao)
  on conflict (uid) do update set descricao = coalesce(excluded.descricao, public.cartoes_rfid.descricao)
  returning * into c;

  select * into v_ant from public.cartoes_rfid_vinculos where cartao_id = c.id and fim is null for update;
  if found then
    if v_ant.operador_id = p_operador_id then
      return jsonb_build_object('cartao_id', c.id, 'uid', c.uid, 'vinculo_id', v_ant.id, 'alterado', false);
    end if;
    update public.cartoes_rfid_vinculos
       set fim = now(), encerrado_por = auth.uid(), motivo = coalesce(p_motivo, 'TROCA_DE_OPERADOR')
     where id = v_ant.id;
  end if;

  insert into public.cartoes_rfid_vinculos (cartao_id, operador_id, inicio, motivo, vinculado_por)
  values (c.id, p_operador_id, clock_timestamp(), p_motivo, auth.uid())
  returning * into v_novo;

  return jsonb_build_object('cartao_id', c.id, 'uid', c.uid, 'vinculo_id', v_novo.id,
                            'operador_anterior', v_ant.operador_id, 'alterado', true);
end $$;

create or replace function public.admin_cartao_desvincular(p_uid text, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir_papel('ADMIN', 'SUPERVISOR');
  update public.cartoes_rfid_vinculos v
     set fim = now(), encerrado_por = auth.uid(), motivo = coalesce(p_motivo, 'DESVINCULADO')
    from public.cartoes_rfid c
   where c.id = v.cartao_id and c.uid = public.fn_normalizar_uid(p_uid) and v.fim is null;
end $$;

create or replace function public.admin_cartao_alterar_status(p_uid text, p_status public.cartao_status,
                                                              p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._exigir_papel('ADMIN', 'SUPERVISOR');
  update public.cartoes_rfid set status = p_status where uid = public.fn_normalizar_uid(p_uid);
  if not found then raise exception 'Cartao inexistente' using errcode = 'P0002'; end if;
  perform public._auditar('APP_WEB', 'CARTAO_STATUS', 'cartoes_rfid', public.fn_normalizar_uid(p_uid), null, null,
                          null, null, null, null, jsonb_build_object('status', p_status),
                          jsonb_build_object('motivo', p_motivo));
end $$;

-- -----------------------------------------------------------------------------
--  Estoque manual (entrada de matéria-prima, saída, ajuste de inventário) — idempotente
-- -----------------------------------------------------------------------------
create or replace function public.admin_estoque_lancar(
  p_event_id uuid, p_tipo public.movimento_tipo, p_item_id uuid, p_armazem_id uuid,
  p_quantidade numeric, p_peso_kg numeric default null, p_sentido smallint default null,
  p_observacao text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sentido smallint;
  v_un      public.unidade_estoque;
  v_id      bigint;
  m         public.estoque_movimentos;
begin
  perform public._exigir_papel('ADMIN', 'SUPERVISOR');
  if p_event_id is null then raise exception 'p_event_id obrigatorio (idempotencia)' using errcode = '22023'; end if;
  if p_tipo in ('SAIDA_CONSUMO_PESAGEM', 'ENTRADA_PRODUCAO_PESAGEM') then
    raise exception 'Movimentos de pesagem só são gerados pela confirmação da pesagem' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('estoque_manual:' || p_event_id::text, 0));
  select * into m from public.estoque_movimentos where event_id = p_event_id and pesagem_id is null;
  if found then
    return jsonb_build_object('movimento_id', m.id, 'replay', true, 'saldo_quantidade', m.saldo_quantidade_apos);
  end if;

  v_sentido := case p_tipo when 'ENTRADA_MANUAL' then 1 when 'SAIDA_MANUAL' then -1 else p_sentido end;
  if v_sentido is null or v_sentido not in (-1, 1) then
    raise exception 'AJUSTE_INVENTARIO exige p_sentido = 1 ou -1' using errcode = '22023';
  end if;
  select unidade into v_un from public.itens_estoque where id = p_item_id;
  v_id := public._estoque_lancar(p_tipo, v_sentido, p_item_id, p_armazem_id, p_quantidade,
                                 coalesce(p_peso_kg, case when v_un = 'KG' then p_quantidade else 0 end),
                                 gen_random_uuid(), null, null, null, null, 'APP_WEB', p_event_id, p_observacao, now());
  select * into m from public.estoque_movimentos where id = v_id;
  return jsonb_build_object('movimento_id', v_id, 'replay', false, 'saldo_quantidade', m.saldo_quantidade_apos,
                            'saldo_peso_kg', m.saldo_peso_apos);
end $$;

-- -----------------------------------------------------------------------------
--  Encerramento forçado (terminal quebrado, operador foi embora...) — SUPERVISOR
-- -----------------------------------------------------------------------------
create or replace function public.admin_sessao_encerrar(p_sessao_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sessoes_pesagem;
begin
  perform public._exigir_papel('ADMIN', 'SUPERVISOR');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Motivo obrigatorio' using errcode = '22023'; end if;
  select * into s from public.sessoes_pesagem where id = p_sessao_id for update;
  if not found then raise exception 'Sessao inexistente' using errcode = 'P0002'; end if;

  if s.status = 'PESAGEM_EM_ANDAMENTO' then
    update public.pesagens set status = 'CANCELADA', motivo = 'SESSAO_ENCERRADA_PELO_SUPERVISOR'
     where sessao_id = s.id and status in ('REGISTRADA', 'DENTRO_TOLERANCIA');
    perform public._sessao_recalcular_totais(s.id);
    update public.sessoes_pesagem
       set status = 'FINALIZADA', finalizada_em = greatest(now(), iniciada_em), motivo_encerramento = p_motivo,
           encerramento_origem = 'APP_WEB', encerrado_por = auth.uid()
     where id = s.id returning * into s;
  elsif s.status not in ('FINALIZADA', 'CANCELADA') then
    update public.sessoes_pesagem
       set status = 'CANCELADA', cancelada_em = now(), motivo_encerramento = p_motivo,
           encerramento_origem = 'APP_WEB', encerrado_por = auth.uid()
     where id = s.id returning * into s;
  else
    raise exception 'Sessao ja esta %', s.status using errcode = 'P0001';
  end if;
  perform public._auditar('APP_WEB', 'SESSAO_ENCERRADA_SUPERVISOR', 'sessoes_pesagem', s.id::text, s.terminal_id,
                          s.operador_id, s.id, null, null, null, jsonb_build_object('status', s.status),
                          jsonb_build_object('motivo', p_motivo));
  return public._sessao_json(s);
end $$;
