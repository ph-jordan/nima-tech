-- =============================================================================
--  TERMINAL DE PESAGEM — 06 · VIEWS DE INDICADORES (APP/WEB e relatórios)
-- -----------------------------------------------------------------------------
--  Todas com security_invoker = true: respeitam o RLS de quem consulta.
--  Datas "do dia" no fuso America/Sao_Paulo.
-- =============================================================================

-- Sessão completa: quem, onde, o quê, tolerância aplicada, totais, duração
create or replace view public.vw_sessoes_resumo with (security_invoker = true) as
select
  s.id                     as sessao_id,
  s.numero,
  s.status,
  s.terminal_id,  t.nome   as terminal,
  s.local_id,     l.nome   as local,
  s.operador_id,  s.operador_nome as operador,  s.cartao_uid,
  s.produto_id,   pr.nome  as produto,
  s.peso_nominal_kg,
  s.tipo_embalagem_id, te.nome as embalagem,
  s.regra_tolerancia_id, s.tolerancia_modo, s.tolerancia_inferior, s.tolerancia_superior,
  s.limite_min_kg, s.limite_max_kg,
  io.codigo as item_origem,  ao.codigo as armazem_origem,
  idt.codigo as item_destino, ad.codigo as armazem_destino,
  s.identificado_em, s.iniciada_em, s.finalizada_em, s.cancelada_em, s.motivo_encerramento,
  s.qtd_pesagens, s.qtd_validas, s.qtd_fora_tolerancia, s.qtd_rejeitadas, s.qtd_canceladas,
  s.unidades_produzidas, s.peso_total_lido_kg, s.peso_valido_kg, s.peso_rejeitado_kg, s.estoque_consumido_kg,
  s.duracao_pesagem_seg, s.duracao_total_seg,
  case when s.qtd_pesagens > 0 then round(100.0 * s.qtd_validas / s.qtd_pesagens, 2) end as taxa_aprovacao_pct,
  case when s.qtd_validas > 0 then round(s.peso_valido_kg / s.qtd_validas, 3) end        as peso_medio_valido_kg,
  case when s.duracao_pesagem_seg > 0 then round(s.qtd_validas / (s.duracao_pesagem_seg / 3600.0), 1) end as unidades_por_hora
from public.sessoes_pesagem s
join public.terminais t             on t.id  = s.terminal_id
left join public.locais l           on l.id  = s.local_id
left join public.produtos pr        on pr.id = s.produto_id
left join public.tipos_embalagem te on te.id = s.tipo_embalagem_id
left join public.itens_estoque io   on io.id = s.item_origem_id
left join public.itens_estoque idt  on idt.id = s.item_destino_id
left join public.armazens ao        on ao.id = s.armazem_origem_id
left join public.armazens ad        on ad.id = s.armazem_destino_id;

-- Pesagem individual com contexto ("Quem pesou? Quando? Onde? Qual tolerância? Aprovada?")
create or replace view public.vw_pesagens_detalhe with (security_invoker = true) as
select
  p.id as pesagem_id, p.sessao_id, s.numero as sessao_numero, p.sequencia, p.sequencia_terminal,
  p.event_id, p.terminal_id, t.nome as terminal, p.operador_id, o.nome as operador,
  p.produto_id, pr.nome as produto, p.tipo_embalagem_id, te.nome as embalagem,
  p.peso_nominal_kg, p.peso_lido, p.unidade, p.peso_lido_kg,
  round(p.peso_lido_kg - p.peso_nominal_kg, 3) as desvio_kg,
  p.regra_tolerancia_id, p.tolerancia_modo, p.tolerancia_inferior, p.tolerancia_superior,
  p.limite_min_kg, p.limite_max_kg, p.resultado, p.status, p.contabilizada, p.motivo,
  p.leitura_estavel, p.lido_em, p.confirmado_em, p.registrado_em, p.origem,
  (select jsonb_agg(jsonb_build_object('tipo', m.tipo, 'item_id', m.item_id, 'armazem_id', m.armazem_id,
                                       'quantidade', m.quantidade, 'unidade', m.unidade, 'peso_kg', m.peso_kg))
     from public.estoque_movimentos m where m.pesagem_id = p.id) as movimentos
from public.pesagens p
join public.sessoes_pesagem s       on s.id  = p.sessao_id
join public.terminais t             on t.id  = p.terminal_id
join public.operadores o            on o.id  = p.operador_id
join public.produtos pr             on pr.id = p.produto_id
join public.tipos_embalagem te      on te.id = p.tipo_embalagem_id;

-- Saldos de estoque legíveis
create or replace view public.vw_estoque_saldos with (security_invoker = true) as
select es.item_id, i.codigo as item_codigo, i.nome as item, i.tipo as item_tipo, i.unidade,
       es.armazem_id, a.codigo as armazem_codigo, a.nome as armazem,
       es.quantidade, es.peso_kg, es.atualizado_em,
       (es.quantidade < 0) as negativo
from public.estoque_saldos es
join public.itens_estoque i on i.id = es.item_id
join public.armazens a      on a.id = es.armazem_id;

-- Situação dos terminais (online/offline pelo heartbeat)
create or replace view public.vw_terminais_status with (security_invoker = true) as
select t.id as terminal_id, t.device_id, t.nome, t.status, l.nome as local, t.localizacao,
       t.firmware_versao, t.ultimo_heartbeat, t.ultimo_sync_em, t.eventos_pendentes, t.ultimo_ip, t.ultimo_rssi,
       t.estado_reportado,
       (t.ultimo_heartbeat is not null and t.ultimo_heartbeat >
          now() - make_interval(secs => coalesce((select (valor #>> '{}')::numeric from public.config_operacao
                                                  where chave = 'terminal_offline_apos_seg'), 120)))
         as online,
       s.id as sessao_aberta_id, s.status as sessao_aberta_status, s.operador_nome as sessao_aberta_operador
from public.terminais t
left join public.locais l on l.id = t.local_id
left join public.sessoes_pesagem s on s.terminal_id = t.id and s.status not in ('FINALIZADA', 'CANCELADA');

-- Produção diária por produto/embalagem/peso/local
create or replace view public.vw_producao_diaria with (security_invoker = true) as
select
  (p.lido_em at time zone 'America/Sao_Paulo')::date as dia,
  s.local_id, l.nome as local,
  p.produto_id, pr.nome as produto, p.peso_nominal_kg, p.tipo_embalagem_id, te.nome as embalagem,
  count(*)                                                      as pesagens,
  count(*) filter (where p.contabilizada)                       as validas,
  count(*) filter (where p.status = 'FORA_TOLERANCIA')          as fora_tolerancia,
  count(*) filter (where p.status = 'REJEITADA')                as rejeitadas,
  coalesce(sum(p.peso_lido_kg), 0)                              as kg_pesados,
  coalesce(sum(p.peso_lido_kg) filter (where p.contabilizada), 0) as kg_aprovados,
  coalesce(sum(p.peso_lido_kg) filter (where p.status in ('FORA_TOLERANCIA', 'REJEITADA')), 0) as kg_rejeitados,
  coalesce(sum(p.peso_lido_kg - p.peso_nominal_kg) filter (where p.contabilizada), 0) as kg_excedente_entregue
from public.pesagens p
join public.sessoes_pesagem s  on s.id  = p.sessao_id
left join public.locais l      on l.id  = s.local_id
join public.produtos pr        on pr.id = p.produto_id
join public.tipos_embalagem te on te.id = p.tipo_embalagem_id
group by 1, 2, 3, 4, 5, 6, 7, 8;

-- Produtividade por operador/dia
create or replace view public.vw_produtividade_operador with (security_invoker = true) as
select
  (p.lido_em at time zone 'America/Sao_Paulo')::date as dia,
  p.operador_id, o.nome as operador,
  count(distinct p.sessao_id)                                    as sessoes,
  count(*)                                                       as pesagens,
  count(*) filter (where p.contabilizada)                        as validas,
  count(*) filter (where p.status = 'FORA_TOLERANCIA')           as fora_tolerancia,
  round(100.0 * count(*) filter (where p.contabilizada) / nullif(count(*), 0), 2) as taxa_aprovacao_pct,
  coalesce(sum(p.peso_lido_kg) filter (where p.contabilizada), 0) as kg_aprovados,
  coalesce(sum(p.peso_lido_kg) filter (where not p.contabilizada), 0) as kg_nao_aprovados
from public.pesagens p
join public.operadores o on o.id = p.operador_id
group by 1, 2, 3;

-- Consumo/produção por armazém e item/dia (estoque consumido e estoque produzido)
create or replace view public.vw_estoque_movimento_diario with (security_invoker = true) as
select (m.ocorrido_em at time zone 'America/Sao_Paulo')::date as dia,
       m.armazem_id, a.codigo as armazem, m.item_id, i.codigo as item, i.unidade, m.tipo,
       count(*) as movimentos,
       sum(m.quantidade) as quantidade,
       sum(m.peso_kg)    as peso_kg
from public.estoque_movimentos m
join public.armazens a      on a.id = m.armazem_id
join public.itens_estoque i on i.id = m.item_id
group by 1, 2, 3, 4, 5, 6, 7;

grant select on public.vw_sessoes_resumo, public.vw_pesagens_detalhe, public.vw_estoque_saldos,
                public.vw_terminais_status, public.vw_producao_diaria, public.vw_produtividade_operador,
                public.vw_estoque_movimento_diario
  to authenticated;
revoke all on public.vw_sessoes_resumo, public.vw_pesagens_detalhe, public.vw_estoque_saldos,
              public.vw_terminais_status, public.vw_producao_diaria, public.vw_produtividade_operador,
              public.vw_estoque_movimento_diario
  from anon;

-- Realtime (opcional): o APP/WEB pode assinar mudanças de sessões, pesagens, saldos e terminais
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.sessoes_pesagem, public.pesagens,
                                                  public.estoque_saldos, public.terminais;
  end if;
end $$;
