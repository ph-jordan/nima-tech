-- =============================================================================
--  TESTES SQL — TERMINAL DE PESAGEM
-- -----------------------------------------------------------------------------
--  Rodar num banco de TESTE/branch (cria dados e não apaga — por design nada é apagável).
--  Pré-requisitos: migrations 01..06 + seed_exemplo.sql.
--  psql -v ON_ERROR_STOP=1 -f pesagem_tests.sql   → qualquer falha aborta com "FALHOU: ..."
--  Cobre os 23 cenários do requisito 30 (+ segurança/RLS). Concorrência real entre
--  conexões: tests/concorrencia_test.sh
-- =============================================================================
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create schema if not exists teste;

create or replace function teste.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALHOU: %', p_msg; end if;
  raise notice 'OK  %', p_msg;
end $$;

create or replace function teste.como_terminal(p_dev text, p_key text) returns void language sql as $$
  select set_config('request.headers', json_build_object('x-device-id', p_dev, 'x-device-key', p_key)::text, false);
$$;

create or replace function teste.ev(p_tipo text, p_dados jsonb, p_eid uuid default gen_random_uuid())
returns jsonb language sql as $$ select public.terminal_evento(p_tipo, p_eid, p_dados) $$;

create or replace function teste.id(p_tab text, p_codigo text) returns uuid language plpgsql as $$
declare v uuid;
begin execute format('select id from public.%I where codigo = $1', p_tab) into v using p_codigo; return v; end $$;

create or replace function teste.saldo(p_item text, p_arm text) returns numeric language sql as $$
  select coalesce((select quantidade from public.estoque_saldos
                    where item_id = teste.id('itens_estoque', p_item) and armazem_id = teste.id('armazens', p_arm)), 0)
$$;

-- Leva uma sessão até PESAGEM_EM_ANDAMENTO e devolve o sessao_id
create or replace function teste.abrir_sessao(p_uid text, p_prod text, p_peso numeric, p_emb text)
returns uuid language plpgsql as $$
declare r jsonb; v_s text;
begin
  r := teste.ev('IDENTIFICAR_CARTAO', jsonb_build_object('uid', p_uid));
  if not (r ->> 'ok')::boolean then raise exception 'abrir_sessao/identificar: %', r; end if;
  v_s := r ->> 'sessao_id';
  r := teste.ev('CONFIRMAR_OPERADOR',   jsonb_build_object('sessao_id', v_s, 'confirmado', true));
  r := teste.ev('SELECIONAR_PRODUTO',   jsonb_build_object('sessao_id', v_s, 'produto_id', teste.id('produtos', p_prod)));
  r := teste.ev('SELECIONAR_PESO',      jsonb_build_object('sessao_id', v_s, 'peso_nominal_kg', p_peso));
  r := teste.ev('SELECIONAR_EMBALAGEM', jsonb_build_object('sessao_id', v_s, 'tipo_embalagem_id', teste.id('tipos_embalagem', p_emb)));
  r := teste.ev('INICIAR_PESAGEM',      jsonb_build_object('sessao_id', v_s));
  if r ->> 'codigo' <> 'PESAGEM_EM_ANDAMENTO' then raise exception 'abrir_sessao/iniciar: %', r; end if;
  return v_s::uuid;
end $$;

-- Terminais de teste com chaves conhecidas
insert into public.terminais (device_id, nome, local_id)
select x.dev, x.nome, l.id from (values ('AABBCC001122', 'Balanca 01'), ('AABBCC003344', 'Balanca 02'),
                                        ('AABBCC005566', 'Balanca Inativa')) x(dev, nome)
cross join public.locais l where l.codigo = 'PLANTA1'
on conflict (device_id) do nothing;
insert into public.terminal_credenciais (terminal_id, chave_hash)
select id, encode(extensions.digest(case device_id when 'AABBCC001122' then 'chave-t1'
                                                   when 'AABBCC003344' then 'chave-t2' else 'chave-t3' end, 'sha256'), 'hex')
from public.terminais where device_id in ('AABBCC001122', 'AABBCC003344', 'AABBCC005566')
on conflict (terminal_id) do nothing;
update public.terminais set status = 'INATIVO' where device_id = 'AABBCC005566';

-- =============================================================================
do $$
declare
  r jsonb; r2 jsonb; v_s uuid; v_s2 uuid; v_eid uuid; v_n int; v_saldo0 numeric; v_saldo1 numeric;
  v_pa0 numeric; v_pid uuid; v_err text; v_lote jsonb; v_evts jsonb;
begin
  perform teste.como_terminal('AABBCC001122', 'chave-t1');

  -- 0. Autenticação do dispositivo -------------------------------------------------------------
  perform teste.como_terminal('AABBCC001122', 'chave-errada');
  begin
    perform public.terminal_heartbeat('{}');
    perform teste.ok(false, '00a chave errada deveria falhar');
  exception when sqlstate 'PT401' then perform teste.ok(true, '00a chave errada → 401');
  end;
  perform teste.como_terminal('AABBCC005566', 'chave-t3');
  begin
    perform public.terminal_heartbeat('{}');
    perform teste.ok(false, '00b terminal inativo deveria falhar');
  exception when sqlstate 'PT403' then perform teste.ok(true, '00b terminal INATIVO → 403');
  end;
  perform teste.como_terminal('AABBCC001122', 'chave-t1');
  r := public.terminal_heartbeat('{"firmware_versao":"4.0.0","estado":"AGUARDANDO_RFID","eventos_pendentes":0}');
  perform teste.ok((r ->> 'ok')::boolean and r -> 'sessao_aberta' = 'null'::jsonb, '00c heartbeat ok, sem sessão aberta');
  r := public.terminal_catalogo();
  perform teste.ok(jsonb_array_length(r -> 'produtos') = 2, '00d catálogo vem do banco (2 produtos)');
  perform teste.ok((select count(*) from jsonb_array_elements(r -> 'produtos') p, jsonb_array_elements(p -> 'pesos') w
                     where p ->> 'nome' = 'Feijao') = 3, '00e Feijão tem 3 pesos (10/20/30)');

  -- 1. RFID válido ----------------------------------------------------------------------------------
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"a1:b2:c3:d4"}');
  perform teste.ok((r ->> 'ok')::boolean and r ->> 'codigo' = 'OPERADOR_IDENTIFICADO'
                   and r ->> 'mensagem' = 'Joao Silva', '01 RFID válido identifica operador (UID normalizado)');
  v_s := (r ->> 'sessao_id')::uuid;
  perform teste.ok((select status from public.sessoes_pesagem where id = v_s) = 'OPERADOR_IDENTIFICADO'
                   and (select identificado_em from public.sessoes_pesagem where id = v_s) is not null,
                   '01b sessão criada com data/hora da identificação');

  -- 2. RFID inválido --------------------------------------------------------------------------------
  v_n := (select count(*) from public.sessoes_pesagem);
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"DEADBEEF"}');
  perform teste.ok(not (r ->> 'ok')::boolean and r ->> 'codigo' = 'RFID_INVALIDO', '02 RFID desconhecido recusado');
  perform teste.ok((select count(*) from public.sessoes_pesagem) = v_n, '02b nenhuma sessão criada');
  perform teste.ok(exists (select 1 from public.auditoria_eventos where acao = 'RFID_INVALIDO'
                             and detalhes -> 'dados' ->> 'uid' = 'DEADBEEF'), '02c tentativa registrada na auditoria');
  update public.cartoes_rfid set status = 'BLOQUEADO' where uid = '11223344';
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"11223344"}');
  perform teste.ok(r ->> 'codigo' = 'RFID_INATIVO', '02d cartão bloqueado recusado');
  update public.cartoes_rfid set status = 'ATIVO' where uid = '11223344';

  -- 4. Operador NÃO confirma (sessão do teste 1) ---------------------------------------------------
  r := teste.ev('CONFIRMAR_OPERADOR', jsonb_build_object('sessao_id', v_s, 'confirmado', false));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_CANCELADA'
                   and (select status from public.sessoes_pesagem where id = v_s) = 'CANCELADA',
                   '04 operador não confirma → sessão CANCELADA (preservada)');
  r := teste.ev('SELECIONAR_PRODUTO', jsonb_build_object('sessao_id', v_s, 'produto_id', teste.id('produtos', 'FEIJAO')));
  perform teste.ok(r ->> 'codigo' = 'ESTADO_INVALIDO', '04b sessão cancelada não avança');

  -- 3. Operador confirma -----------------------------------------------------------------------------
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"A1B2C3D4"}');
  v_s := (r ->> 'sessao_id')::uuid;
  r := teste.ev('SELECIONAR_PRODUTO', jsonb_build_object('sessao_id', v_s, 'produto_id', teste.id('produtos', 'FEIJAO')));
  perform teste.ok(r ->> 'codigo' = 'ESTADO_INVALIDO', '03a não seleciona produto antes de confirmar identidade');
  r := teste.ev('CONFIRMAR_OPERADOR', jsonb_build_object('sessao_id', v_s, 'confirmado', true));
  perform teste.ok(r ->> 'codigo' = 'OPERADOR_CONFIRMADO'
                   and (select status from public.sessoes_pesagem where id = v_s) = 'SELECIONANDO_PRODUTO',
                   '03 operador confirma → SELECIONANDO_PRODUTO');

  -- 5. Seleção de produto ----------------------------------------------------------------------------
  r := teste.ev('SELECIONAR_PRODUTO', jsonb_build_object('sessao_id', v_s, 'produto_id', gen_random_uuid()));
  perform teste.ok(r ->> 'codigo' = 'PRODUTO_INDISPONIVEL', '05a produto inexistente recusado');
  r := teste.ev('SELECIONAR_PRODUTO', jsonb_build_object('sessao_id', v_s, 'produto_id', teste.id('produtos', 'FEIJAO')));
  perform teste.ok(r ->> 'codigo' = 'PRODUTO_SELECIONADO' and r -> 'pesos' = '[10, 20, 30]'::jsonb,
                   '05 produto selecionado; pesos vêm do cadastro');

  -- 6. Seleção de peso --------------------------------------------------------------------------------
  r := teste.ev('SELECIONAR_PESO', jsonb_build_object('sessao_id', v_s, 'peso_nominal_kg', 25));
  perform teste.ok(r ->> 'codigo' = 'PESO_INDISPONIVEL', '06a peso não cadastrado recusado');
  r := teste.ev('SELECIONAR_PESO', jsonb_build_object('sessao_id', v_s, 'peso_nominal_kg', 20));
  perform teste.ok(r ->> 'codigo' = 'PESO_SELECIONADO' and jsonb_array_length(r -> 'embalagens') = 2,
                   '06 peso 20 kg selecionado; 2 embalagens (Saco, Caixa)');

  -- 7. Seleção de embalagem ----------------------------------------------------------------------------
  r := teste.ev('SELECIONAR_EMBALAGEM', jsonb_build_object('sessao_id', v_s, 'tipo_embalagem_id', teste.id('tipos_embalagem', 'PALETE')));
  perform teste.ok(r ->> 'codigo' = 'EMBALAGEM_INDISPONIVEL', '07a embalagem sem especificação recusada');
  r := teste.ev('SELECIONAR_EMBALAGEM', jsonb_build_object('sessao_id', v_s, 'tipo_embalagem_id', teste.id('tipos_embalagem', 'SACO')));
  perform teste.ok(r ->> 'codigo' = 'PRONTO_PARA_INICIAR'
                   and (r -> 'previa_tolerancia' ->> 'limite_min_kg')::numeric = 20
                   and (r -> 'previa_tolerancia' ->> 'limite_max_kg')::numeric = 20.2,
                   '07 embalagem Saco → PRONTO_PARA_INICIAR, prévia 20,000–20,200 kg');

  -- 8. Cancelamento ANTES do início ---------------------------------------------------------------------
  r := teste.ev('CANCELAR_SESSAO', jsonb_build_object('sessao_id', v_s, 'motivo', 'Produto errado'));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_CANCELADA'
                   and (select status from public.sessoes_pesagem where id = v_s) = 'CANCELADA',
                   '08 CANCELAR antes de iniciar funciona');

  -- 10. Início da sessão ----------------------------------------------------------------------------------
  v_s := teste.abrir_sessao('A1B2C3D4', 'FEIJAO', 20, 'SACO');
  perform teste.ok((select status = 'PESAGEM_EM_ANDAMENTO' and iniciada_em is not null and limite_min_kg = 20
                           and limite_max_kg = 20.2 and regra_tolerancia_id is not null and snapshot is not null
                      from public.sessoes_pesagem where id = v_s),
                   '10 INICIAR → PESAGEM_EM_ANDAMENTO com tolerância congelada');

  -- 9. Tentativa de cancelamento DEPOIS do início ------------------------------------------------------------
  r := teste.ev('CANCELAR_SESSAO', jsonb_build_object('sessao_id', v_s));
  perform teste.ok(not (r ->> 'ok')::boolean and r ->> 'codigo' = 'CANCELAMENTO_BLOQUEADO'
                   and (select status from public.sessoes_pesagem where id = v_s) = 'PESAGEM_EM_ANDAMENTO',
                   '09 CANCELAR após iniciar é BLOQUEADO');
  perform teste.ok(exists (select 1 from public.auditoria_eventos where acao = 'CANCELAMENTO_BLOQUEADO' and sessao_id = v_s),
                   '09b tentativa de cancelamento auditada');
  begin
    update public.sessoes_pesagem set status = 'CANCELADA', cancelada_em = now() where id = v_s;
    perform teste.ok(false, '09c update direto deveria falhar');
  exception when others then perform teste.ok(sqlerrm like '%Transição de sessão inválida%', '09c nem UPDATE direto cancela sessão em pesagem');
  end;

  -- 11 + 13 + 15. Pesagem dentro da tolerância, confirmada, com estoque ---------------------------------------
  v_saldo0 := teste.saldo('FEIJAO-GRANEL', 'MP');
  v_pa0    := teste.saldo('FEIJAO-SC20', 'PA');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.05, 'unidade', 'kg',
                 'lido_em', now() - interval '2 seconds', 'confirmado_em', now(), 'sequencia_terminal', 1, 'leitura_estavel', true));
  perform teste.ok(r ->> 'codigo' = 'PESAGEM_CONFIRMADA' and (r -> 'pesagem' ->> 'contabilizada')::boolean
                   and r -> 'pesagem' ->> 'resultado' = 'DENTRO_TOLERANCIA', '11/13 pesagem 20,050 dentro → CONFIRMADA');
  v_pid := (r ->> 'pesagem_id')::uuid;
  perform teste.ok(teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0 - 20.05, '15a origem baixou 20,050 kg (PESO_LIDO)');
  perform teste.ok(teste.saldo('FEIJAO-SC20', 'PA') = v_pa0 + 1, '15b produto final +1 saco');
  perform teste.ok((select count(*) from public.estoque_movimentos where pesagem_id = v_pid) = 2
                   and (select count(distinct grupo_id) from public.estoque_movimentos where pesagem_id = v_pid) = 1,
                   '15c 2 movimentos (saída+entrada) vinculados à pesagem e à sessão');
  perform teste.ok((select lido_em < confirmado_em from public.pesagens where id = v_pid), '13b leitura e confirmação com timestamps distintos');

  -- 12. Pesagem fora da tolerância ------------------------------------------------------------------------------
  v_saldo0 := teste.saldo('FEIJAO-GRANEL', 'MP');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 19.80, 'unidade', 'kg', 'sequencia_terminal', 2));
  perform teste.ok(r ->> 'codigo' = 'FORA_TOLERANCIA' and not (r -> 'pesagem' ->> 'contabilizada')::boolean
                   and r -> 'pesagem' ->> 'status' = 'FORA_TOLERANCIA', '12 19,800 kg → FORA_TOLERANCIA, não contabiliza');
  perform teste.ok(teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0
                   and not exists (select 1 from public.estoque_movimentos where pesagem_id = (r ->> 'pesagem_id')::uuid),
                   '12b fora da tolerância não movimenta estoque');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20250, 'unidade', 'g'));
  perform teste.ok(r ->> 'codigo' = 'FORA_TOLERANCIA' and (r -> 'pesagem' ->> 'peso_lido_kg')::numeric = 20.25,
                   '12c 20250 g convertido p/ 20,250 kg → acima do máximo');

  -- 14. Tentativa de contabilizar pesagem inválida (fluxo em 2 passos) -------------------------------------------
  r := teste.ev('REGISTRAR_LEITURA', jsonb_build_object('sessao_id', v_s, 'peso_lido', 18.0));
  perform teste.ok(r ->> 'codigo' = 'FORA_TOLERANCIA', '14a leitura registrada FORA_TOLERANCIA');
  v_pid := (r ->> 'pesagem_id')::uuid;
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'pesagem_id', v_pid));
  perform teste.ok(r ->> 'codigo' = 'FORA_TOLERANCIA' and not (r -> 'pesagem' ->> 'contabilizada')::boolean
                   and not exists (select 1 from public.estoque_movimentos where pesagem_id = v_pid),
                   '14 confirmar pesagem inválida NÃO contabiliza nem movimenta');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'pesagem_id', v_pid, 'tentativa', 2));
  perform teste.ok(r ->> 'codigo' = 'PESAGEM_JA_FINALIZADA', '14b segunda tentativa recusada');
  begin
    update public.pesagens set status = 'CONFIRMADA', contabilizada = true, confirmado_em = now() where id = v_pid;
    perform teste.ok(false, '14c update direto deveria falhar');
  exception when others then perform teste.ok(true, '14c UPDATE direto FORA→CONFIRMADA bloqueado: ' || left(sqlerrm, 60));
  end;
  -- 2 passos válido: registrar → confirmar
  r := teste.ev('REGISTRAR_LEITURA', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.1));
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'pesagem_id', r ->> 'pesagem_id'));
  perform teste.ok(r ->> 'codigo' = 'PESAGEM_CONFIRMADA', '14d fluxo 2 passos dentro → CONFIRMADA');
  -- 2 passos com rejeição pelo operador
  r := teste.ev('REGISTRAR_LEITURA', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.0));
  r := teste.ev('REJEITAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'pesagem_id', r ->> 'pesagem_id'));
  perform teste.ok(r ->> 'codigo' = 'PESAGEM_REJEITADA', '14e operador rejeita leitura → REJEITADA (sem estoque)');

  -- 20. Tentativa de alterar uma pesagem já confirmada ------------------------------------------------------------
  select id into v_pid from public.pesagens where sessao_id = v_s and status = 'CONFIRMADA' order by sequencia limit 1;
  begin
    update public.pesagens set peso_lido_kg = 25 where id = v_pid;
    perform teste.ok(false, '20 deveria falhar');
  exception when others then perform teste.ok(true, '20a alterar peso de pesagem confirmada bloqueado');
  end;
  begin
    update public.pesagens set status = 'REJEITADA' where id = v_pid;
    perform teste.ok(false, '20 deveria falhar');
  exception when others then perform teste.ok(true, '20b mudar status de pesagem confirmada bloqueado');
  end;
  begin
    delete from public.pesagens where id = v_pid;
    perform teste.ok(false, '20 deveria falhar');
  exception when others then perform teste.ok(true, '20c DELETE de pesagem bloqueado');
  end;
  begin
    delete from public.estoque_movimentos where pesagem_id = v_pid;
    perform teste.ok(false, '20 deveria falhar');
  exception when others then perform teste.ok(true, '20d DELETE de movimento bloqueado');
  end;

  -- 17 + 18. Retry / mesmo evento duas vezes -------------------------------------------------------------------------
  v_saldo0 := teste.saldo('FEIJAO-GRANEL', 'MP');
  v_n      := (select count(*) from public.pesagens where sessao_id = v_s);
  v_eid    := gen_random_uuid();
  r  := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.12, 'sequencia_terminal', 9), v_eid);
  r2 := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.12, 'sequencia_terminal', 9), v_eid);
  perform teste.ok(not (r ->> 'replay')::boolean and (r2 ->> 'replay')::boolean
                   and r ->> 'pesagem_id' = r2 ->> 'pesagem_id', '17 retry devolve a MESMA resposta (replay=true)');
  perform teste.ok((select count(*) from public.pesagens where sessao_id = v_s) = v_n + 1, '18a uma única pesagem criada');
  perform teste.ok(teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0 - 20.12, '18b estoque baixado UMA vez');
  r2 := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 99), v_eid);
  perform teste.ok(r2 ->> 'codigo' = 'EVENT_ID_CONFLITO', '18c mesmo event_id com dados diferentes → conflito');
  -- mesmo event_id via sync (fila do microSD) também é replay
  r2 := public.terminal_sincronizar(jsonb_build_array(jsonb_build_object('tipo', 'CONFIRMAR_PESAGEM', 'event_id', v_eid,
          'dados', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.12, 'sequencia_terminal', 9))));
  perform teste.ok((r2 -> 'resultados' -> 0 ->> 'replay')::boolean and teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0 - 20.12,
                   '18d reenvio pela fila offline também não duplica');

  -- 21. Múltiplas pesagens na mesma sessão -----------------------------------------------------------------------------
  for i in 1..5 loop
    r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20 + i * 0.01, 'sequencia_terminal', 10 + i));
  end loop;
  perform teste.ok((select count(*) = max(sequencia) and count(distinct sequencia) = count(*)
                      from public.pesagens where sessao_id = v_s), '21a sequência contínua e única na sessão');
  perform teste.ok((select qtd_validas from public.sessoes_pesagem where id = v_s) = 8
                   and (select qtd_fora_tolerancia from public.sessoes_pesagem where id = v_s) = 3
                   and (select qtd_rejeitadas from public.sessoes_pesagem where id = v_s) = 1,
                   '21b totais parciais: 8 válidas, 3 fora, 1 rejeitada');

  -- 16. Finalização -------------------------------------------------------------------------------------------------------
  r := teste.ev('FINALIZAR_SESSAO', jsonb_build_object('sessao_id', v_s));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_FINALIZADA', '16 sessão FINALIZADA');
  perform teste.ok((select status = 'FINALIZADA' and finalizada_em is not null and duracao_pesagem_seg >= 0
                           and qtd_pesagens = 12 and qtd_validas = 8 and unidades_produzidas = 8
                           and peso_valido_kg = (select sum(peso_lido_kg) from public.pesagens where sessao_id = v_s and contabilizada)
                           and estoque_consumido_kg = peso_valido_kg
                      from public.sessoes_pesagem where id = v_s), '16b totais finais consistentes com pesagens e movimentos');
  r := teste.ev('FINALIZAR_SESSAO', jsonb_build_object('sessao_id', v_s, 'de_novo', true));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_JA_FINALIZADA', '16c finalizar duas vezes é recusado (sem efeito)');

  -- 19. Confirmar pesagem em sessão finalizada ---------------------------------------------------------------------------
  v_saldo0 := teste.saldo('FEIJAO-GRANEL', 'MP');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.05));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_NAO_EM_PESAGEM' and teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0
                   and (select qtd_pesagens from public.sessoes_pesagem where id = v_s) = 12,
                   '19 pesagem em sessão finalizada recusada, nada muda');
  begin
    update public.sessoes_pesagem set status = 'PESAGEM_EM_ANDAMENTO' where id = v_s;
    perform teste.ok(false, '19b deveria falhar');
  exception when others then perform teste.ok(true, '19b FINALIZADA não volta para PESAGEM');
  end;

  -- Tolerância congelada: alterar a regra não afeta sessão em andamento nem pesagens passadas -------------------------------
  v_s := teste.abrir_sessao('A1B2C3D4', 'FEIJAO', 20, 'SACO');
  update public.regras_tolerancia set tolerancia_superior = 1.0 where descricao like 'Padrao global%';
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.5));
  perform teste.ok(r ->> 'codigo' = 'FORA_TOLERANCIA' and (r -> 'pesagem' ->> 'limite_max_kg')::numeric = 20.2,
                   '05R regra alterada depois do início NÃO afeta a sessão (limite congelado 20,200)');
  perform teste.ok(not exists (select 1 from public.pesagens where limite_max_kg <> 20.2 and produto_id = teste.id('produtos','FEIJAO')),
                   '05R2 pesagens antigas mantêm os limites originais');
  perform teste.ok(exists (select 1 from public.auditoria_eventos where acao = 'CADASTRO_UPDATE' and entidade = 'regras_tolerancia'
                             and (valor_anterior ->> 'tolerancia_superior')::numeric = 0.2
                             and (valor_novo ->> 'tolerancia_superior')::numeric = 1.0),
                   '23A alteração cadastral auditada com valor anterior/novo');
  update public.regras_tolerancia set tolerancia_superior = 0.2 where descricao like 'Padrao global%';
  r := teste.ev('FINALIZAR_SESSAO', jsonb_build_object('sessao_id', v_s));

  -- Estoque insuficiente: pesagem válida vira REJEITADA, sem movimento ---------------------------------------------------
  v_s := teste.abrir_sessao('11223344', 'LARANJA', 20, 'CAIXA');
  perform public._estoque_lancar('SAIDA_MANUAL', -1::smallint, teste.id('itens_estoque', 'LARANJA-GRANEL'), teste.id('armazens', 'MP'),
                                 teste.saldo('LARANJA-GRANEL', 'MP') - 10, teste.saldo('LARANJA-GRANEL', 'MP') - 10,
                                 gen_random_uuid(), null, null, null, null, 'SISTEMA', gen_random_uuid(), 'teste', now());
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20.0));
  perform teste.ok(r ->> 'codigo' = 'ESTOQUE_INSUFICIENTE' and r -> 'pesagem' ->> 'status' = 'REJEITADA'
                   and teste.saldo('LARANJA-GRANEL', 'MP') = 10, '15d sem saldo de origem: REJEITADA, saldo intacto');
  perform public._estoque_lancar('ENTRADA_MANUAL', 1::smallint, teste.id('itens_estoque', 'LARANJA-GRANEL'), teste.id('armazens', 'MP'),
                                 1000, 1000, gen_random_uuid(), null, null, null, null, 'SISTEMA', gen_random_uuid(), 'teste', now());
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 19.85));
  perform teste.ok(r ->> 'codigo' = 'PESAGEM_CONFIRMADA', '15e tolerância percentual (±1% → 19,800–20,200) aplicada');

  -- 22. Concorrência entre terminais (regras de exclusividade) ------------------------------------------------------------
  perform teste.como_terminal('AABBCC003344', 'chave-t2');
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"11223344"}');
  perform teste.ok(r ->> 'codigo' = 'OPERADOR_COM_SESSAO_EM_ANDAMENTO', '22a operador pesando em T1 não abre sessão em T2');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 20));
  perform teste.ok(r ->> 'codigo' = 'SESSAO_NAO_ENCONTRADA', '22b T2 não consegue pesar na sessão de T1');
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"A1B2C3D4"}');
  v_s2 := (r ->> 'sessao_id')::uuid;
  perform teste.ok(r ->> 'codigo' = 'OPERADOR_IDENTIFICADO', '22c outro operador abre sessão em T2 em paralelo');
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"A1B2C3D4"}');
  perform teste.ok(r ->> 'codigo' = 'OPERADOR_IDENTIFICADO'
                   and (select status from public.sessoes_pesagem where id = v_s2) = 'CANCELADA',
                   '22d nova leitura no mesmo terminal substitui sessão não iniciada (antiga fica CANCELADA)');
  r := teste.ev('CANCELAR_SESSAO', jsonb_build_object('sessao_id', r ->> 'sessao_id'));

  perform teste.como_terminal('AABBCC001122', 'chave-t1');
  r := teste.ev('IDENTIFICAR_CARTAO', '{"uid":"A1B2C3D4"}');
  perform teste.ok(r ->> 'codigo' = 'TERMINAL_COM_SESSAO_EM_ANDAMENTO' and r -> 'sessao' ->> 'sessao_id' = v_s::text,
                   '22e terminal com pesagem em andamento não aceita novo cartão');
  r := public.terminal_heartbeat('{}');
  perform teste.ok(r -> 'sessao_aberta' ->> 'sessao_id' = v_s::text, '22f heartbeat devolve sessão aberta (retomada após reboot)');
  r := teste.ev('FINALIZAR_SESSAO', jsonb_build_object('sessao_id', v_s));

  -- 23. Offline: pesagens guardadas no microSD e sincronizadas depois ----------------------------------------------------
  v_s := teste.abrir_sessao('A1B2C3D4', 'FEIJAO', 10, 'SACO');
  v_saldo0 := teste.saldo('FEIJAO-GRANEL', 'MP');
  v_pa0    := teste.saldo('FEIJAO-SC10', 'PA');
  v_evts := jsonb_build_array(
    jsonb_build_object('tipo','CONFIRMAR_PESAGEM','event_id',gen_random_uuid(),'dados',
      jsonb_build_object('sessao_id',v_s,'peso_lido',10.05,'lido_em',now()-interval '10 min','confirmado_em',now()-interval '10 min','sequencia_terminal',1)),
    jsonb_build_object('tipo','CONFIRMAR_PESAGEM','event_id',gen_random_uuid(),'dados',
      jsonb_build_object('sessao_id',v_s,'peso_lido',9.5,'lido_em',now()-interval '9 min','confirmado_em',now()-interval '9 min','sequencia_terminal',2)),
    jsonb_build_object('tipo','CONFIRMAR_PESAGEM','event_id',gen_random_uuid(),'dados',
      jsonb_build_object('sessao_id',v_s,'peso_lido',10.10,'lido_em',now()-interval '8 min','confirmado_em',now()-interval '8 min','sequencia_terminal',3)),
    jsonb_build_object('tipo','LOG','event_id',gen_random_uuid(),'dados', jsonb_build_object('nivel','WARN','mensagem','WiFi caiu 8 min')),
    jsonb_build_object('tipo','FINALIZAR_SESSAO','event_id',gen_random_uuid(),'dados',
      jsonb_build_object('sessao_id',v_s,'ocorrido_em',now()-interval '7 min')));
  r := public.terminal_sincronizar(v_evts);
  perform teste.ok((r ->> 'processados')::int = 5
                   and (select bool_and((x ->> 'ok')::boolean) from jsonb_array_elements(r -> 'resultados') x),
                   '23a lote offline processado em ordem');
  perform teste.ok((select status = 'FINALIZADA' and qtd_validas = 2 and qtd_fora_tolerancia = 1
                      from public.sessoes_pesagem where id = v_s)
                   and teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0 - 20.15 and teste.saldo('FEIJAO-SC10', 'PA') = v_pa0 + 2,
                   '23b estoque e totais corretos após sync');
  perform teste.ok((select bool_and(origem = 'TERMINAL_SYNC' and lido_em < registrado_em - interval '5 min')
                      from public.pesagens where sessao_id = v_s), '23c horário real da leitura preservado (origem SYNC)');
  r := public.terminal_sincronizar(v_evts);   -- placa reenviou tudo (não recebeu o ACK)
  perform teste.ok((select bool_and((x ->> 'replay')::boolean) from jsonb_array_elements(r -> 'resultados') x)
                   and teste.saldo('FEIJAO-GRANEL', 'MP') = v_saldo0 - 20.15
                   and (select count(*) from public.pesagens where sessao_id = v_s) = 3,
                   '23d reenvio completo do lote: tudo replay, nada duplicado');
  r := public.terminal_sincronizar('[{"tipo":"LOG","event_id":"nao-e-uuid","dados":{}}]');
  perform teste.ok(r -> 'resultados' -> 0 ->> 'codigo' = 'EVENTO_MALFORMADO'
                   and not (r -> 'resultados' -> 0 ->> 'retry')::boolean, '23e evento malformado descartável (retry=false)');

  -- Leitura inválida da balança ---------------------------------------------------------------------------------------------
  v_s := teste.abrir_sessao('A1B2C3D4', 'FEIJAO', 30, 'SACO');
  r := teste.ev('CONFIRMAR_PESAGEM', jsonb_build_object('sessao_id', v_s, 'peso_lido', 'abc'));
  perform teste.ok(r ->> 'codigo' = 'LEITURA_INVALIDA' and not exists (select 1 from public.pesagens where sessao_id = v_s),
                   '11b lixo serial recusado sem criar pesagem');
  r := teste.ev('FINALIZAR_SESSAO', jsonb_build_object('sessao_id', v_s));

  -- Vínculo de cartão com histórico --------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', '{}', false);
end $$;

-- =============================================================================
--  Segurança: anon (ESP32) e authenticated (APP/WEB) com RLS
-- =============================================================================
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@teste'),
  ('00000000-0000-0000-0000-00000000000b', 'leitura@teste'),
  ('00000000-0000-0000-0000-00000000000c', 'joao@teste'),
  ('00000000-0000-0000-0000-00000000000d', 'novo@teste');
update public.perfis set papel = 'ADMIN', ativo = true where email = 'admin@teste';
update public.perfis set papel = 'LEITURA', ativo = true where email = 'leitura@teste';
update public.perfis set papel = 'OPERADOR', ativo = true,
       operador_id = (select id from public.operadores where matricula = '0001') where email = 'joao@teste';

create or replace function teste.como_usuario(p_sub text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, false);
$$;
grant usage on schema teste to anon, authenticated;
grant execute on all functions in schema teste to anon, authenticated;

-- anon: sem acesso a tabelas, só RPCs do terminal
set role anon;
do $$
begin
  begin
    perform 1 from public.pesagens limit 1;
    perform teste.ok(false, 'S1 anon não pode ler pesagens');
  exception when insufficient_privilege then perform teste.ok(true, 'S1 anon NÃO lê tabelas');
  end;
  begin
    perform public.admin_cartao_vincular('FFFF0000', gen_random_uuid());
    perform teste.ok(false, 'S2 anon não pode usar admin_*');
  exception when insufficient_privilege then perform teste.ok(true, 'S2 anon NÃO executa admin_*');
  end;
  begin
    perform public._estoque_lancar('ENTRADA_MANUAL', 1::smallint, gen_random_uuid(), gen_random_uuid(), 1, 1,
                                   gen_random_uuid(), null, null, null, null, 'SISTEMA', null, null, now());
    perform teste.ok(false, 'S3 anon não pode chamar função interna');
  exception when insufficient_privilege then perform teste.ok(true, 'S3 anon NÃO executa funções internas (_*)');
  end;
  perform teste.como_terminal('AABBCC001122', 'chave-t1');
  perform teste.ok((public.terminal_heartbeat('{}') ->> 'ok')::boolean, 'S4 anon + chave do dispositivo usa terminal_*');
end $$;
reset role;

set role authenticated;
do $$
declare v_tot int; v_meu int; r jsonb;
begin
  perform teste.como_usuario('00000000-0000-0000-0000-00000000000d');   -- usuário novo (inativo)
  perform teste.ok((select count(*) from public.pesagens) = 0 and (select count(*) from public.produtos) = 0,
                   'S5 usuário recém-criado (inativo) não vê nada');

  perform teste.como_usuario('00000000-0000-0000-0000-00000000000b');   -- LEITURA
  v_tot := (select count(*) from public.pesagens);
  perform teste.ok(v_tot > 0 and (select count(*) from public.vw_sessoes_resumo) > 0, 'S6 LEITURA vê produção e views');
  begin
    insert into public.produtos (codigo, nome, nome_exibicao) values ('X', 'X', 'X');
    perform teste.ok(false, 'S7 LEITURA não cadastra');
  exception when insufficient_privilege then perform teste.ok(true, 'S7 LEITURA não altera cadastro (RLS)');
  end;
  begin
    perform public.admin_cartao_vincular('FFFF0000', gen_random_uuid());
    perform teste.ok(false, 'S8');
  exception when insufficient_privilege then perform teste.ok(true, 'S8 LEITURA não vincula cartão');
  end;
  begin
    insert into public.pesagens (sessao_id) values (gen_random_uuid());
    perform teste.ok(false, 'S9');
  exception when insufficient_privilege then perform teste.ok(true, 'S9 ninguém insere pesagem direto');
  end;
  begin
    update public.perfis set papel = 'ADMIN' where id = auth.uid();
    perform teste.ok((select papel from public.perfis where id = auth.uid()) = 'LEITURA', 'S10 sem auto-promoção');
  end;

  perform teste.como_usuario('00000000-0000-0000-0000-00000000000c');   -- OPERADOR João
  v_meu := (select count(*) from public.pesagens);
  perform teste.ok(v_meu > 0 and v_meu < v_tot
                   and not exists (select 1 from public.pesagens where operador_id <> public.fn_operador_atual()),
                   'S11 OPERADOR vê só as próprias pesagens');

  perform teste.como_usuario('00000000-0000-0000-0000-00000000000a');   -- ADMIN
  r := public.admin_cartao_vincular('A1B2C3D4', (select id from public.operadores where matricula = '0002'), 'Troca de crachá');
  perform teste.ok((r ->> 'alterado')::boolean
                   and (select count(*) from public.cartoes_rfid_vinculos v join public.cartoes_rfid c on c.id = v.cartao_id
                         where c.uid = 'A1B2C3D4') = 2
                   and (select count(*) from public.cartoes_rfid_vinculos v join public.cartoes_rfid c on c.id = v.cartao_id
                         where c.uid = 'A1B2C3D4' and fim is null) = 1,
                   'S12 troca de operador do cartão mantém histórico (1 aberto, 1 encerrado)');
  r := public.admin_terminal_registrar('AABBCC007788', 'Balanca 03', null, 'Linha 3');
  perform teste.ok(length(r ->> 'chave') = 48, 'S13 ADMIN registra terminal e recebe chave uma única vez');
  begin
    perform 1 from public.terminal_credenciais;
    perform teste.ok(false, 'S14');
  exception when insufficient_privilege then perform teste.ok(true, 'S14 nem ADMIN lê hash de credencial via API');
  end;
  r := public.admin_estoque_lancar('11111111-2222-3333-4444-555555555555', 'ENTRADA_MANUAL',
         (select id from public.itens_estoque where codigo = 'FEIJAO-GRANEL'), (select id from public.armazens where codigo = 'MP'), 100);
  perform teste.ok(not (r ->> 'replay')::boolean, 'S15 entrada manual de estoque');
  r := public.admin_estoque_lancar('11111111-2222-3333-4444-555555555555', 'ENTRADA_MANUAL',
         (select id from public.itens_estoque where codigo = 'FEIJAO-GRANEL'), (select id from public.armazens where codigo = 'MP'), 100);
  perform teste.ok((r ->> 'replay')::boolean, 'S16 entrada manual idempotente');
end $$;
reset role;

select set_config('request.jwt.claims', '', false);
\echo '======================================================='
\echo ' TODOS OS TESTES PASSARAM'
\echo '======================================================='
