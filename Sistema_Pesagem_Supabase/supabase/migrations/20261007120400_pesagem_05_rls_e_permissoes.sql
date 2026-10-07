-- =============================================================================
--  TERMINAL DE PESAGEM — 05 · RLS, POLICIES E PERMISSÕES
-- -----------------------------------------------------------------------------
--  Papéis (public.perfis.papel):
--    ADMIN       tudo: cadastros, terminais, configurações, perfis
--    SUPERVISOR  cadastros operacionais, cartões, ajustes de estoque, encerrar sessão; lê tudo
--    LEITURA     lê produção, estoque, cadastros (relatórios/dashboards)
--    OPERADOR    lê cadastros/estoque e apenas as PRÓPRIAS sessões/pesagens
--  anon (= ESP32): nenhuma tabela. Só EXECUTE em terminal_* (autenticadas por chave do dispositivo).
--  Ninguém escreve diretamente em sessões, pesagens, movimentos, saldos, inbox ou auditoria:
--  só as funções SECURITY DEFINER escrevem.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  RLS ligado em todas as tabelas
-- -----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locais','operadores','perfis','cartoes_rfid','cartoes_rfid_vinculos','terminais',
                           'terminal_credenciais','tipos_embalagem','produtos','armazens','itens_estoque',
                           'produto_embalagens','regras_tolerancia','config_operacao','sessoes_pesagem','pesagens',
                           'estoque_saldos','estoque_movimentos','terminal_eventos','auditoria_eventos']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
--  Privilégios de tabela (defesa em profundidade, além do RLS)
-- -----------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;

revoke all on public.terminal_credenciais from authenticated;
revoke insert, update, delete, truncate on
  public.sessoes_pesagem, public.pesagens, public.estoque_saldos, public.estoque_movimentos,
  public.terminal_eventos, public.auditoria_eventos, public.cartoes_rfid_vinculos
from authenticated;
revoke truncate on all tables in schema public from authenticated;

-- -----------------------------------------------------------------------------
--  Cadastros: todos os perfis ativos leem; escrita por papel
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
  -- tabela → papéis que escrevem
  cad jsonb := '{
    "locais":             ["ADMIN"],
    "armazens":           ["ADMIN"],
    "terminais":          ["ADMIN"],
    "config_operacao":    ["ADMIN"],
    "operadores":         ["ADMIN","SUPERVISOR"],
    "cartoes_rfid":       ["ADMIN","SUPERVISOR"],
    "tipos_embalagem":    ["ADMIN","SUPERVISOR"],
    "produtos":           ["ADMIN","SUPERVISOR"],
    "itens_estoque":      ["ADMIN","SUPERVISOR"],
    "produto_embalagens": ["ADMIN","SUPERVISOR"],
    "regras_tolerancia":  ["ADMIN","SUPERVISOR"]
  }';
  v_papeis text;
begin
  for t in select jsonb_object_keys(cad) loop
    select string_agg(format('%L', x), ',') into v_papeis from jsonb_array_elements_text(cad -> t) x;
    execute format('create policy %I on public.%I for select to authenticated using (public.fn_papel_atual() is not null)',
                   t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.fn_tem_papel(%s))',
                   t || '_insert', t, v_papeis);
    execute format('create policy %I on public.%I for update to authenticated using (public.fn_tem_papel(%s)) with check (public.fn_tem_papel(%s))',
                   t || '_update', t, v_papeis, v_papeis);
    execute format('create policy %I on public.%I for delete to authenticated using (public.fn_tem_papel(''ADMIN''))',
                   t || '_delete', t);
  end loop;
end $$;

-- vínculos de cartão: leitura (escrita só via admin_cartao_vincular)
create policy cartoes_rfid_vinculos_select on public.cartoes_rfid_vinculos for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR', 'LEITURA')
         or operador_id = public.fn_operador_atual());

-- perfis: cada um vê o seu; ADMIN/SUPERVISOR veem todos; só ADMIN altera (evita auto-promoção)
create policy perfis_select on public.perfis for select to authenticated
  using (id = auth.uid() or public.fn_tem_papel('ADMIN', 'SUPERVISOR'));
create policy perfis_update on public.perfis for update to authenticated
  using (public.fn_tem_papel('ADMIN')) with check (public.fn_tem_papel('ADMIN'));
create policy perfis_insert on public.perfis for insert to authenticated
  with check (public.fn_tem_papel('ADMIN'));

-- terminal_credenciais: SEM policy → inacessível via API (só funções definer)

-- -----------------------------------------------------------------------------
--  Operação: somente leitura via API
-- -----------------------------------------------------------------------------
create policy sessoes_select on public.sessoes_pesagem for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR', 'LEITURA') or operador_id = public.fn_operador_atual());

create policy pesagens_select on public.pesagens for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR', 'LEITURA') or operador_id = public.fn_operador_atual());

create policy movimentos_select on public.estoque_movimentos for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR', 'LEITURA') or operador_id = public.fn_operador_atual());

create policy saldos_select on public.estoque_saldos for select to authenticated
  using (public.fn_papel_atual() is not null);

create policy terminal_eventos_select on public.terminal_eventos for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR'));

create policy auditoria_select on public.auditoria_eventos for select to authenticated
  using (public.fn_tem_papel('ADMIN', 'SUPERVISOR'));

-- -----------------------------------------------------------------------------
--  EXECUTE de funções
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

-- ESP32 (anon + cabeçalhos do dispositivo)
grant execute on function public.terminal_evento(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.terminal_sincronizar(jsonb)        to anon, authenticated;
grant execute on function public.terminal_heartbeat(jsonb)          to anon, authenticated;
grant execute on function public.terminal_catalogo()                to anon, authenticated;

-- APP/WEB
grant execute on function public.fn_papel_atual()                                     to authenticated;
grant execute on function public.fn_tem_papel(public.papel_usuario[])                 to authenticated;
grant execute on function public.fn_operador_atual()                                  to authenticated;
grant execute on function public.fn_normalizar_uid(text)                              to authenticated;
grant execute on function public.fn_limites_tolerancia(numeric, public.tolerancia_modo, numeric, numeric) to authenticated;
grant execute on function public.fn_sessao_transicao_valida(public.sessao_status, public.sessao_status)   to authenticated;
grant execute on function public.fn_pesagem_transicao_valida(public.pesagem_status, public.pesagem_status) to authenticated;
grant execute on function public.admin_terminal_registrar(text, text, uuid, text)                to authenticated;
grant execute on function public.admin_terminal_alterar_status(uuid, public.terminal_status)    to authenticated;
grant execute on function public.admin_cartao_vincular(text, uuid, text, text)                  to authenticated;
grant execute on function public.admin_cartao_desvincular(text, text)                           to authenticated;
grant execute on function public.admin_cartao_alterar_status(text, public.cartao_status, text)  to authenticated;
grant execute on function public.admin_estoque_lancar(uuid, public.movimento_tipo, uuid, uuid, numeric, numeric, smallint, text) to authenticated;
grant execute on function public.admin_sessao_encerrar(uuid, text)                              to authenticated;
