-- =============================================================================
--  TERMINAL DE PESAGEM — 02 · TRIGGERS DE INTEGRIDADE + FUNÇÕES INTERNAS
-- -----------------------------------------------------------------------------
--  Triggers só onde são indispensáveis:
--    · atualizado_em
--    · normalização do UID RFID
--    · validação da especificação produto/embalagem
--    · máquina de estados da SESSÃO (bloqueia transições inválidas)
--    · máquina de estados da PESAGEM (bloqueia alteração de pesagem final)
--    · registros append-only (movimentos, inbox, auditoria) e proibição de DELETE
--    · auditoria de alterações cadastrais
--    · criação de perfil para novo usuário do Auth
--  Funções com prefixo "_" são internas: sem EXECUTE para anon/authenticated.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  Utilitários
-- -----------------------------------------------------------------------------
create or replace function public._trg_atualizado_em()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['locais','operadores','perfis','cartoes_rfid','terminais','tipos_embalagem',
                           'produtos','armazens','itens_estoque','produto_embalagens','regras_tolerancia',
                           'config_operacao','sessoes_pesagem','pesagens']
  loop
    execute format('create trigger trg_%s_atualizado_em before update on public.%I
                    for each row execute function public._trg_atualizado_em()', t, t);
  end loop;
end $$;

create or replace function public.fn_normalizar_uid(p_uid text)
returns text language sql immutable set search_path = '' as $$
  select nullif(upper(regexp_replace(coalesce(p_uid, ''), '[^0-9A-Fa-f]', '', 'g')), '')
$$;

create or replace function public._trg_cartao_normaliza_uid()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.uid := public.fn_normalizar_uid(new.uid);
  return new;
end $$;
create trigger trg_cartao_normaliza_uid before insert or update of uid on public.cartoes_rfid
  for each row execute function public._trg_cartao_normaliza_uid();

create or replace function public._trg_terminal_normaliza_device()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.device_id := upper(regexp_replace(new.device_id, '[^0-9A-Fa-f]', '', 'g'));
  return new;
end $$;
create trigger trg_terminal_normaliza_device before insert or update of device_id on public.terminais
  for each row execute function public._trg_terminal_normaliza_device();

-- Converte timestamp vindo do dispositivo. Relógio sem NTP (1970) ou no futuro → hora do servidor.
create or replace function public._ts_dispositivo(p_ts text)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare v timestamptz;
begin
  if p_ts is null or p_ts = '' then return now(); end if;
  begin
    v := p_ts::timestamptz;
  exception when others then
    return now();
  end;
  if v < timestamptz '2024-01-01' or v > now() + interval '5 minutes' then
    return now();
  end if;
  return v;
end $$;

create or replace function public._config(p_chave text, p_padrao jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select valor from public.config_operacao where chave = p_chave), p_padrao)
$$;

-- -----------------------------------------------------------------------------
--  Auditoria
-- -----------------------------------------------------------------------------
create or replace function public._auditar(
  p_origem public.evento_origem, p_acao text,
  p_entidade text default null, p_entidade_id text default null,
  p_terminal_id uuid default null, p_operador_id uuid default null,
  p_sessao_id uuid default null, p_pesagem_id uuid default null,
  p_event_id uuid default null,
  p_valor_anterior jsonb default null, p_valor_novo jsonb default null,
  p_detalhes jsonb default null, p_ocorrido_em timestamptz default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.auditoria_eventos
    (ocorrido_em, origem, acao, entidade, entidade_id, usuario_id, operador_id, terminal_id,
     sessao_id, pesagem_id, event_id, valor_anterior, valor_novo, detalhes)
  values
    (coalesce(p_ocorrido_em, now()), p_origem, p_acao, p_entidade, p_entidade_id, auth.uid(), p_operador_id,
     p_terminal_id, p_sessao_id, p_pesagem_id, p_event_id, p_valor_anterior, p_valor_novo, p_detalhes)
$$;

-- Auditoria genérica de cadastro (valor anterior/novo). TG_ARGV = colunas ignoradas.
create or replace function public._trg_auditar_cadastro()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_ign  text[] := coalesce(tg_argv::text[], '{}'::text[]) || array['atualizado_em'];
  v_old  jsonb;
  v_new  jsonb;
  v_id   text;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old) - v_ign; end if;
  if tg_op in ('UPDATE', 'INSERT') then v_new := to_jsonb(new) - v_ign; end if;
  if tg_op = 'UPDATE' and v_old = v_new then
    return new;
  end if;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'chave', v_old ->> 'chave',
                   v_new ->> 'terminal_id', v_old ->> 'terminal_id');
  insert into public.auditoria_eventos (origem, acao, entidade, entidade_id, usuario_id, valor_anterior, valor_novo)
  values (case when auth.uid() is null then 'SISTEMA' else 'APP_WEB' end::public.evento_origem,
          'CADASTRO_' || tg_op, tg_table_name, v_id, auth.uid(), v_old, v_new);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['locais','operadores','perfis','cartoes_rfid','cartoes_rfid_vinculos','tipos_embalagem',
                           'produtos','armazens','itens_estoque','produto_embalagens','regras_tolerancia',
                           'config_operacao']
  loop
    execute format('create trigger trg_%s_auditoria after insert or update or delete on public.%I
                    for each row execute function public._trg_auditar_cadastro()', t, t);
  end loop;
end $$;
-- terminais: ignora colunas de telemetria (heartbeat não polui a auditoria)
create trigger trg_terminais_auditoria after insert or update or delete on public.terminais
  for each row execute function public._trg_auditar_cadastro(
    'ultimo_heartbeat', 'ultimo_ip', 'ultimo_rssi', 'estado_reportado', 'eventos_pendentes', 'ultimo_sync_em', 'firmware_versao');
-- credenciais: audita sem expor o hash
create trigger trg_credenciais_auditoria after insert or update or delete on public.terminal_credenciais
  for each row execute function public._trg_auditar_cadastro('chave_hash');

-- -----------------------------------------------------------------------------
--  Registros que nunca podem ser apagados / alterados
-- -----------------------------------------------------------------------------
create or replace function public._trg_bloquear_delete()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'Registros de % não podem ser apagados (rastreabilidade).', tg_table_name
    using errcode = 'P0001', hint = 'Use status/ativo, nunca DELETE.';
end $$;

create or replace function public._trg_bloquear_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'Registros de % são imutáveis (append-only).', tg_table_name using errcode = 'P0001';
end $$;

do $$
declare t text;
begin
  foreach t in array array['sessoes_pesagem','pesagens','estoque_movimentos','terminal_eventos',
                           'auditoria_eventos','cartoes_rfid_vinculos']
  loop
    execute format('create trigger trg_%s_sem_delete before delete on public.%I
                    for each row execute function public._trg_bloquear_delete()', t, t);
  end loop;
  foreach t in array array['estoque_movimentos','terminal_eventos','auditoria_eventos']
  loop
    execute format('create trigger trg_%s_sem_update before update on public.%I
                    for each row execute function public._trg_bloquear_update()', t, t);
  end loop;
end $$;

-- TRUNCATE também bloqueado nas tabelas operacionais
create or replace function public._trg_bloquear_truncate()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'TRUNCATE em % não é permitido.', tg_table_name using errcode = 'P0001';
end $$;
do $$
declare t text;
begin
  foreach t in array array['sessoes_pesagem','pesagens','estoque_movimentos','terminal_eventos','auditoria_eventos',
                           'cartoes_rfid_vinculos','estoque_saldos']
  loop
    execute format('create trigger trg_%s_sem_truncate before truncate on public.%I
                    for each statement execute function public._trg_bloquear_truncate()', t, t);
  end loop;
end $$;

-- Vínculo de cartão: só pode ser ENCERRADO (fim/encerrado_por/motivo), nunca reescrito
create or replace function public._trg_vinculo_somente_encerrar()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.fim is not null then
    raise exception 'Vínculo de cartão já encerrado é imutável.' using errcode = 'P0001';
  end if;
  if new.cartao_id <> old.cartao_id or new.operador_id <> old.operador_id or new.inicio <> old.inicio
     or new.criado_em <> old.criado_em then
    raise exception 'Vínculo de cartão só pode ser encerrado, não alterado.' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger trg_vinculo_somente_encerrar before update on public.cartoes_rfid_vinculos
  for each row execute function public._trg_vinculo_somente_encerrar();

-- -----------------------------------------------------------------------------
--  Validação da especificação produto/embalagem
-- -----------------------------------------------------------------------------
create or replace function public._trg_validar_produto_embalagem()
returns trigger language plpgsql set search_path = '' as $$
declare v_un public.unidade_estoque;
begin
  select unidade into v_un from public.itens_estoque where id = new.item_origem_id;
  if v_un <> 'KG' then
    raise exception 'Item de origem precisa ser controlado em KG (é consumido por peso).' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger trg_validar_produto_embalagem before insert or update on public.produto_embalagens
  for each row execute function public._trg_validar_produto_embalagem();

-- -----------------------------------------------------------------------------
--  Máquina de estados da SESSÃO
-- -----------------------------------------------------------------------------
create or replace function public.fn_sessao_transicao_valida(p_de public.sessao_status, p_para public.sessao_status)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when p_de = p_para then p_de not in ('FINALIZADA', 'CANCELADA')
    when p_de = 'AGUARDANDO_RFID'       then p_para = 'OPERADOR_IDENTIFICADO'
    when p_de = 'OPERADOR_IDENTIFICADO' then p_para in ('SELECIONANDO_PRODUTO', 'CANCELADA')
    when p_de in ('SELECIONANDO_PRODUTO', 'SELECIONANDO_PESO', 'SELECIONANDO_EMBALAGEM', 'PRONTO_PARA_INICIAR')
         then p_para in ('SELECIONANDO_PRODUTO', 'SELECIONANDO_PESO', 'SELECIONANDO_EMBALAGEM',
                         'PRONTO_PARA_INICIAR', 'CANCELADA')
              or (p_de = 'PRONTO_PARA_INICIAR' and p_para = 'PESAGEM_EM_ANDAMENTO')
    when p_de = 'PESAGEM_EM_ANDAMENTO'  then p_para = 'FINALIZADA'   -- CANCELAR bloqueado
    else false                                                       -- FINALIZADA/CANCELADA são terminais
  end
$$;

create or replace function public._trg_sessao_maquina_estados()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not public.fn_sessao_transicao_valida(old.status, new.status) then
    raise exception 'Transição de sessão inválida: % → %', old.status, new.status
      using errcode = 'P0001', hint = 'Após INICIAR PESAGEM só é possível FINALIZAR.';
  end if;
  -- identidade da sessão é imutável
  if new.terminal_id <> old.terminal_id or new.operador_id <> old.operador_id or new.cartao_id <> old.cartao_id
     or new.identificado_em <> old.identificado_em or new.numero <> old.numero then
    raise exception 'Identidade da sessão (terminal/operador/cartão) é imutável.' using errcode = 'P0001';
  end if;
  -- após iniciar, seleção e snapshot de tolerância ficam congelados
  if old.iniciada_em is not null and (
       new.iniciada_em            is distinct from old.iniciada_em
    or new.produto_id             is distinct from old.produto_id
    or new.peso_nominal_kg        is distinct from old.peso_nominal_kg
    or new.tipo_embalagem_id      is distinct from old.tipo_embalagem_id
    or new.produto_embalagem_id   is distinct from old.produto_embalagem_id
    or new.regra_tolerancia_id    is distinct from old.regra_tolerancia_id
    or new.tolerancia_modo        is distinct from old.tolerancia_modo
    or new.tolerancia_inferior    is distinct from old.tolerancia_inferior
    or new.tolerancia_superior    is distinct from old.tolerancia_superior
    or new.limite_min_kg          is distinct from old.limite_min_kg
    or new.limite_max_kg          is distinct from old.limite_max_kg
    or new.item_origem_id         is distinct from old.item_origem_id
    or new.armazem_origem_id      is distinct from old.armazem_origem_id
    or new.item_destino_id        is distinct from old.item_destino_id
    or new.armazem_destino_id     is distinct from old.armazem_destino_id
    or new.unidades_por_pesagem   is distinct from old.unidades_por_pesagem
    or new.base_consumo           is distinct from old.base_consumo
    or new.snapshot               is distinct from old.snapshot) then
    raise exception 'Seleção e tolerância da sessão ficam congeladas após o início da pesagem.' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger trg_sessao_maquina_estados before update on public.sessoes_pesagem
  for each row execute function public._trg_sessao_maquina_estados();

-- -----------------------------------------------------------------------------
--  Máquina de estados da PESAGEM
-- -----------------------------------------------------------------------------
create or replace function public.fn_pesagem_transicao_valida(
  p_de public.pesagem_status, p_para public.pesagem_status)
returns boolean language sql immutable set search_path = '' as $$
  select case p_de
    when 'REGISTRADA'        then p_para in ('DENTRO_TOLERANCIA', 'FORA_TOLERANCIA', 'REJEITADA', 'CANCELADA')
    when 'DENTRO_TOLERANCIA' then p_para in ('CONFIRMADA', 'REJEITADA', 'CANCELADA')
    when 'FORA_TOLERANCIA'   then p_para in ('FORA_TOLERANCIA', 'REJEITADA')  -- FORA→FORA = ciência do operador
    else false                                                                -- CONFIRMADA/REJEITADA/CANCELADA: finais
  end
$$;

create or replace function public._trg_pesagem_maquina_estados()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not public.fn_pesagem_transicao_valida(old.status, new.status) then
    raise exception 'Pesagem % não pode passar de % para %', old.id, old.status, new.status
      using errcode = 'P0001', hint = 'Pesagens confirmadas/rejeitadas/canceladas são imutáveis.';
  end if;
  if old.status = 'FORA_TOLERANCIA' and new.status = 'FORA_TOLERANCIA' and old.confirmado_em is not null then
    raise exception 'Pesagem fora de tolerância já reconhecida é imutável.' using errcode = 'P0001';
  end if;
  -- a medição em si nunca muda
  if (new.sessao_id, new.sequencia, new.event_id, new.terminal_id, new.operador_id, new.produto_id,
      new.produto_embalagem_id, new.tipo_embalagem_id, new.peso_nominal_kg, new.peso_lido, new.unidade,
      new.peso_lido_kg, new.tolerancia_modo, new.tolerancia_inferior, new.tolerancia_superior,
      new.limite_min_kg, new.limite_max_kg, new.resultado, new.lido_em, new.registrado_em, new.origem)
     is distinct from
     (old.sessao_id, old.sequencia, old.event_id, old.terminal_id, old.operador_id, old.produto_id,
      old.produto_embalagem_id, old.tipo_embalagem_id, old.peso_nominal_kg, old.peso_lido, old.unidade,
      old.peso_lido_kg, old.tolerancia_modo, old.tolerancia_inferior, old.tolerancia_superior,
      old.limite_min_kg, old.limite_max_kg, old.resultado, old.lido_em, old.registrado_em, old.origem)
     or new.regra_tolerancia_id is distinct from old.regra_tolerancia_id then
    raise exception 'Os dados medidos de uma pesagem são imutáveis.' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger trg_pesagem_maquina_estados before update on public.pesagens
  for each row execute function public._trg_pesagem_maquina_estados();

-- -----------------------------------------------------------------------------
--  Perfil automático para novo usuário do Auth (inativo até um ADMIN liberar)
-- -----------------------------------------------------------------------------
create or replace function public._trg_novo_usuario_perfil()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.perfis (id, email, nome, papel, ativo)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'nome', new.email), 'LEITURA', false)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger trg_auth_novo_usuario_perfil after insert on auth.users
  for each row execute function public._trg_novo_usuario_perfil();

-- -----------------------------------------------------------------------------
--  Tolerância: resolução da regra vigente e cálculo dos limites
-- -----------------------------------------------------------------------------
create or replace function public._resolver_tolerancia(p_produto_embalagem_id uuid, p_em timestamptz)
returns public.regras_tolerancia language sql stable security definer set search_path = '' as $$
  select r.*
  from public.produto_embalagens pe
  join public.regras_tolerancia r
    on r.ativo
   and r.vigencia_inicio <= p_em
   and (r.vigencia_fim is null or r.vigencia_fim > p_em)
   and (r.produto_embalagem_id is null or r.produto_embalagem_id = pe.id)
   and (r.produto_id           is null or r.produto_id           = pe.produto_id)
   and (r.peso_nominal_kg      is null or r.peso_nominal_kg      = pe.peso_nominal_kg)
   and (r.tipo_embalagem_id    is null or r.tipo_embalagem_id    = pe.tipo_embalagem_id)
  where pe.id = p_produto_embalagem_id
  order by (case when r.produto_embalagem_id is not null then 8 else 0 end
          + case when r.produto_id           is not null then 4 else 0 end
          + case when r.peso_nominal_kg      is not null then 2 else 0 end
          + case when r.tipo_embalagem_id    is not null then 1 else 0 end) desc,
           r.prioridade desc, r.vigencia_inicio desc, r.criado_em desc
  limit 1
$$;

create or replace function public.fn_limites_tolerancia(
  p_nominal numeric, p_modo public.tolerancia_modo, p_inf numeric, p_sup numeric,
  out limite_min_kg numeric, out limite_max_kg numeric)
language sql immutable set search_path = '' as $$
  select case p_modo when 'ABSOLUTA_KG' then round(p_nominal - p_inf, 3)
                     else round(p_nominal * (1 - p_inf / 100.0), 3) end,
         case p_modo when 'ABSOLUTA_KG' then round(p_nominal + p_sup, 3)
                     else round(p_nominal * (1 + p_sup / 100.0), 3) end
$$;

-- Snapshot completo (especificação + regra) num instante: o que será congelado na sessão.
create or replace function public._snapshot_especificacao(p_produto_embalagem_id uuid, p_em timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  pe  public.produto_embalagens;
  r   public.regras_tolerancia;
  lim record;
begin
  select * into pe from public.produto_embalagens where id = p_produto_embalagem_id;
  if not found then return null; end if;
  r := public._resolver_tolerancia(pe.id, p_em);
  if r.id is null then return null; end if;
  select * into lim from public.fn_limites_tolerancia(pe.peso_nominal_kg, r.modo, r.tolerancia_inferior, r.tolerancia_superior);
  return jsonb_build_object(
    'produto_embalagem_id', pe.id,
    'produto_id',           pe.produto_id,
    'peso_nominal_kg',      pe.peso_nominal_kg,
    'tipo_embalagem_id',    pe.tipo_embalagem_id,
    'item_origem_id',       pe.item_origem_id,
    'armazem_origem_id',    pe.armazem_origem_id,
    'item_destino_id',      pe.item_destino_id,
    'armazem_destino_id',   pe.armazem_destino_id,
    'unidades_por_pesagem', pe.unidades_por_pesagem,
    'base_consumo',         pe.base_consumo,
    'regra_tolerancia_id',  r.id,
    'regra_descricao',      r.descricao,
    'tolerancia_modo',      r.modo,
    'tolerancia_inferior',  r.tolerancia_inferior,
    'tolerancia_superior',  r.tolerancia_superior,
    'limite_min_kg',        lim.limite_min_kg,
    'limite_max_kg',        lim.limite_max_kg,
    'resolvido_em',         p_em);
end $$;

-- -----------------------------------------------------------------------------
--  Estoque: único ponto que altera saldo (saldo + movimento na mesma transação)
-- -----------------------------------------------------------------------------
create or replace function public._estoque_lancar(
  p_tipo public.movimento_tipo, p_sentido smallint, p_item_id uuid, p_armazem_id uuid,
  p_quantidade numeric, p_peso_kg numeric, p_grupo_id uuid,
  p_pesagem_id uuid, p_sessao_id uuid, p_terminal_id uuid, p_operador_id uuid,
  p_origem public.evento_origem, p_event_id uuid, p_observacao text, p_ocorrido_em timestamptz)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_item  public.itens_estoque;
  v_arm   public.armazens;
  v_qtd   numeric;
  v_peso  numeric;
  v_id    bigint;
begin
  if p_quantidade is null or p_quantidade <= 0 then
    raise exception 'Quantidade de movimento deve ser > 0' using errcode = '22023';
  end if;
  select * into v_item from public.itens_estoque where id = p_item_id;
  select * into v_arm  from public.armazens      where id = p_armazem_id;
  if v_item.id is null or v_arm.id is null then
    raise exception 'Item ou armazém inexistente' using errcode = '23503';
  end if;

  insert into public.estoque_saldos (item_id, armazem_id) values (p_item_id, p_armazem_id)
  on conflict (item_id, armazem_id) do nothing;

  update public.estoque_saldos
     set quantidade    = quantidade + p_sentido * p_quantidade,
         peso_kg       = peso_kg    + p_sentido * coalesce(p_peso_kg, 0),
         atualizado_em = now()
   where item_id = p_item_id and armazem_id = p_armazem_id
  returning quantidade, peso_kg into v_qtd, v_peso;          -- UPDATE trava a linha: concorrência segura

  if p_sentido < 0 and v_qtd < 0 and not v_arm.permite_estoque_negativo then
    raise exception 'ESTOQUE_INSUFICIENTE: item % no armazém % ficaria com %', v_item.codigo, v_arm.codigo, v_qtd
      using errcode = 'P0010';
  end if;

  insert into public.estoque_movimentos
    (grupo_id, tipo, sentido, item_id, armazem_id, quantidade, unidade, peso_kg,
     saldo_quantidade_apos, saldo_peso_apos, pesagem_id, sessao_id, terminal_id, operador_id,
     usuario_id, origem, event_id, observacao, ocorrido_em)
  values
    (p_grupo_id, p_tipo, p_sentido, p_item_id, p_armazem_id, p_quantidade, v_item.unidade, coalesce(p_peso_kg, 0),
     v_qtd, v_peso, p_pesagem_id, p_sessao_id, p_terminal_id, p_operador_id,
     auth.uid(), p_origem, p_event_id, p_observacao, p_ocorrido_em)
  returning id into v_id;
  return v_id;
end $$;

-- Gera saída da origem + entrada do produto final para uma pesagem CONFIRMADA.
create or replace function public._estoque_movimentar_pesagem(p_pesagem_id uuid, p_origem public.evento_origem)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p          public.pesagens;
  s          public.sessoes_pesagem;
  v_dest_un  public.unidade_estoque;
  v_consumo  numeric;
  v_qtd_dest numeric;
  v_grupo    uuid := gen_random_uuid();
  v_ocorrido timestamptz;
begin
  select * into p from public.pesagens where id = p_pesagem_id;
  select * into s from public.sessoes_pesagem where id = p.sessao_id;
  if p.status <> 'CONFIRMADA' or not p.contabilizada then
    raise exception 'Só pesagem CONFIRMADA e contabilizada movimenta estoque' using errcode = 'P0001';
  end if;

  v_consumo := case s.base_consumo when 'PESO_NOMINAL' then p.peso_nominal_kg else p.peso_lido_kg end;
  select unidade into v_dest_un from public.itens_estoque where id = s.item_destino_id;
  v_qtd_dest := case v_dest_un when 'UN' then s.unidades_por_pesagem else p.peso_lido_kg end;
  v_ocorrido := coalesce(p.confirmado_em, p.lido_em);

  -- ordem fixa de bloqueio: origem e depois destino
  perform public._estoque_lancar('SAIDA_CONSUMO_PESAGEM', -1::smallint, s.item_origem_id, s.armazem_origem_id,
                                 v_consumo, v_consumo, v_grupo, p.id, s.id, p.terminal_id, p.operador_id,
                                 p_origem, p.event_id, null, v_ocorrido);
  perform public._estoque_lancar('ENTRADA_PRODUCAO_PESAGEM', 1::smallint, s.item_destino_id, s.armazem_destino_id,
                                 v_qtd_dest, p.peso_lido_kg, v_grupo, p.id, s.id, p.terminal_id, p.operador_id,
                                 p_origem, p.event_id, null, v_ocorrido);
  return jsonb_build_object('grupo_id', v_grupo,
                            'saida',   jsonb_build_object('item_id', s.item_origem_id,  'armazem_id', s.armazem_origem_id,  'quantidade', v_consumo, 'unidade', 'KG'),
                            'entrada', jsonb_build_object('item_id', s.item_destino_id, 'armazem_id', s.armazem_destino_id, 'quantidade', v_qtd_dest, 'unidade', v_dest_un));
end $$;

-- -----------------------------------------------------------------------------
--  Totais da sessão — sempre recalculados da fonte (pesagens + movimentos)
-- -----------------------------------------------------------------------------
create or replace function public._sessao_recalcular_totais(p_sessao_id uuid)
returns public.sessoes_pesagem language plpgsql security definer set search_path = '' as $$
declare s public.sessoes_pesagem;
begin
  update public.sessoes_pesagem t set
    qtd_pesagens         = a.qtd,
    qtd_validas          = a.validas,
    qtd_fora_tolerancia  = a.fora,
    qtd_rejeitadas       = a.rejeitadas,
    qtd_canceladas       = a.canceladas,
    peso_total_lido_kg   = a.peso_total,
    peso_valido_kg       = a.peso_valido,
    peso_rejeitado_kg    = a.peso_rejeitado,
    unidades_produzidas  = m.unidades,
    estoque_consumido_kg = m.consumido
  from (select count(*)                                                     as qtd,
               count(*) filter (where contabilizada)                        as validas,
               count(*) filter (where status = 'FORA_TOLERANCIA')            as fora,
               count(*) filter (where status = 'REJEITADA')                  as rejeitadas,
               count(*) filter (where status = 'CANCELADA')                  as canceladas,
               coalesce(sum(peso_lido_kg), 0)                                as peso_total,
               coalesce(sum(peso_lido_kg) filter (where contabilizada), 0)   as peso_valido,
               coalesce(sum(peso_lido_kg) filter (where status in ('FORA_TOLERANCIA','REJEITADA')), 0) as peso_rejeitado
          from public.pesagens where sessao_id = p_sessao_id) a,
       (select coalesce(sum(quantidade) filter (where tipo = 'ENTRADA_PRODUCAO_PESAGEM'), 0) as unidades,
               coalesce(sum(peso_kg)    filter (where tipo = 'SAIDA_CONSUMO_PESAGEM'), 0)    as consumido
          from public.estoque_movimentos where sessao_id = p_sessao_id) m
  where t.id = p_sessao_id
  returning t.* into s;
  return s;
end $$;

create or replace function public._sessao_json(s public.sessoes_pesagem)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'sessao_id',            s.id,
    'numero',               s.numero,
    'status',               s.status,
    'operador',             jsonb_build_object('id', s.operador_id, 'nome', o.nome_exibicao),
    'produto',              case when s.produto_id is null then null
                                 else jsonb_build_object('id', s.produto_id, 'nome', pr.nome_exibicao) end,
    'peso_nominal_kg',      s.peso_nominal_kg,
    'embalagem',            case when s.tipo_embalagem_id is null then null
                                 else jsonb_build_object('id', s.tipo_embalagem_id, 'nome', te.nome_exibicao) end,
    'tolerancia',           case when s.iniciada_em is null then null else jsonb_build_object(
                               'regra_id', s.regra_tolerancia_id, 'modo', s.tolerancia_modo,
                               'inferior', s.tolerancia_inferior, 'superior', s.tolerancia_superior,
                               'limite_min_kg', s.limite_min_kg, 'limite_max_kg', s.limite_max_kg) end,
    'iniciada_em',          s.iniciada_em,
    'finalizada_em',        s.finalizada_em,
    'totais', jsonb_build_object(
       'pesagens',             s.qtd_pesagens,
       'validas',              s.qtd_validas,
       'fora_tolerancia',      s.qtd_fora_tolerancia,
       'rejeitadas',           s.qtd_rejeitadas,
       'canceladas',           s.qtd_canceladas,
       'unidades_produzidas',  s.unidades_produzidas,
       'peso_total_lido_kg',   s.peso_total_lido_kg,
       'peso_valido_kg',       s.peso_valido_kg,
       'peso_rejeitado_kg',    s.peso_rejeitado_kg,
       'estoque_consumido_kg', s.estoque_consumido_kg,
       'duracao_seg',          coalesce(s.duracao_pesagem_seg, s.duracao_total_seg)))
  from public.operadores o
  left join public.produtos pr       on pr.id = s.produto_id
  left join public.tipos_embalagem te on te.id = s.tipo_embalagem_id
  where o.id = s.operador_id
$$;
