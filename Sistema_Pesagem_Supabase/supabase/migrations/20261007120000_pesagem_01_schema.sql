-- =============================================================================
--  TERMINAL DE PESAGEM INDUSTRIAL — 01 · SCHEMA (enums, tabelas, índices)
-- -----------------------------------------------------------------------------
--  Camadas (requisito 26 — nada misturado numa tabela só):
--    CADASTRO ........ locais, operadores, cartoes_rfid, cartoes_rfid_vinculos,
--                      terminais, terminal_credenciais, produtos,
--                      tipos_embalagem, armazens, itens_estoque,
--                      produto_embalagens, regras_tolerancia, config_operacao,
--                      perfis
--    SESSÃO .......... sessoes_pesagem
--    PESAGEM ......... pesagens
--    ESTOQUE ......... estoque_saldos, estoque_movimentos
--    LOG/AUDITORIA ... terminal_eventos (inbox idempotente), auditoria_eventos
--
--  Projeto Supabase NOVO: nenhuma tabela pré-existente é alterada.
--  Postgres 15+ (usa UNIQUE NULLS NOT DISTINCT).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
--  ENUMS
-- -----------------------------------------------------------------------------
create type public.sessao_status as enum (
  'AGUARDANDO_RFID',          -- estado do terminal (sem sessão); reservado p/ relatórios
  'OPERADOR_IDENTIFICADO',
  'SELECIONANDO_PRODUTO',
  'SELECIONANDO_PESO',
  'SELECIONANDO_EMBALAGEM',
  'PRONTO_PARA_INICIAR',
  'PESAGEM_EM_ANDAMENTO',
  'FINALIZADA',
  'CANCELADA'
);

create type public.pesagem_status as enum (
  'REGISTRADA',               -- leitura recebida, ainda não validada
  'DENTRO_TOLERANCIA',        -- validada, aguardando confirmação do operador
  'FORA_TOLERANCIA',          -- inválida: nunca contabiliza
  'CONFIRMADA',               -- válida + confirmada = contabilizada (gera estoque)
  'REJEITADA',                -- descartada pelo operador ou por falta de estoque
  'CANCELADA'                 -- leitura pendente quando a sessão foi finalizada
);

create type public.pesagem_resultado as enum ('DENTRO_TOLERANCIA', 'FORA_TOLERANCIA');
create type public.papel_usuario     as enum ('ADMIN', 'SUPERVISOR', 'OPERADOR', 'LEITURA');
create type public.terminal_status   as enum ('ATIVO', 'INATIVO', 'MANUTENCAO');
create type public.cartao_status     as enum ('ATIVO', 'INATIVO', 'BLOQUEADO', 'PERDIDO');
create type public.item_tipo         as enum ('MATERIA_PRIMA', 'PRODUTO_FINAL', 'INSUMO');
create type public.unidade_estoque   as enum ('KG', 'UN');
create type public.tolerancia_modo   as enum ('ABSOLUTA_KG', 'PERCENTUAL');
create type public.base_consumo      as enum ('PESO_LIDO', 'PESO_NOMINAL');
create type public.movimento_tipo    as enum (
  'SAIDA_CONSUMO_PESAGEM',    -- baixa da matéria-prima de origem
  'ENTRADA_PRODUCAO_PESAGEM', -- entrada do produto final embalado
  'ENTRADA_MANUAL',
  'SAIDA_MANUAL',
  'AJUSTE_INVENTARIO'
);
create type public.evento_origem as enum ('TERMINAL', 'TERMINAL_SYNC', 'APP_WEB', 'SISTEMA');

-- -----------------------------------------------------------------------------
--  CADASTROS
-- -----------------------------------------------------------------------------
create table public.locais (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique check (codigo ~ '^[A-Z0-9_-]{1,30}$'),
  nome           text not null,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
comment on table public.locais is 'Unidades/plantas físicas. Permite múltiplos locais com múltiplos terminais.';

create table public.operadores (
  id             uuid primary key default gen_random_uuid(),
  matricula      text not null unique,
  nome           text not null,
  nome_exibicao  text not null check (char_length(nome_exibicao) between 1 and 16),
  local_id       uuid references public.locais(id),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
comment on column public.operadores.nome_exibicao is 'Nome curto exibido no LCD 16x2 (máx. 16 caracteres).';

create table public.perfis (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text,
  nome           text,
  papel          public.papel_usuario not null default 'LEITURA',
  operador_id    uuid unique references public.operadores(id),
  ativo          boolean not null default false,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
comment on table public.perfis is 'Perfil/papel de cada usuário do APP/WEB. Novos usuários nascem INATIVOS com papel LEITURA; um ADMIN ativa.';

create table public.cartoes_rfid (
  id             uuid primary key default gen_random_uuid(),
  uid            text not null unique check (uid ~ '^[0-9A-F]{8,20}$'),
  descricao      text,
  status         public.cartao_status not null default 'ATIVO',
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
comment on column public.cartoes_rfid.uid is 'UID do cartão em HEX maiúsculo sem separadores (ex.: 04A1B2C3). Normalizado por trigger.';

create table public.cartoes_rfid_vinculos (
  id             uuid primary key default gen_random_uuid(),
  cartao_id      uuid not null references public.cartoes_rfid(id),
  operador_id    uuid not null references public.operadores(id),
  inicio         timestamptz not null default now(),
  fim            timestamptz,
  motivo         text,
  vinculado_por  uuid,
  encerrado_por  uuid,
  criado_em      timestamptz not null default now(),
  check (fim is null or fim > inicio)
);
comment on table public.cartoes_rfid_vinculos is 'Histórico cartão→operador. Nunca é apagado; troca de dono encerra o vínculo (fim) e abre outro.';
create unique index ux_cartao_vinculo_aberto on public.cartoes_rfid_vinculos(cartao_id) where fim is null;
create index ix_cartao_vinculo_operador on public.cartoes_rfid_vinculos(operador_id);

create table public.terminais (
  id                 uuid primary key default gen_random_uuid(),
  device_id          text not null unique check (device_id ~ '^[0-9A-F]{6,32}$'),
  nome               text not null,
  local_id           uuid references public.locais(id),
  localizacao        text,
  status             public.terminal_status not null default 'ATIVO',
  firmware_versao    text,
  ultimo_heartbeat   timestamptz,
  ultimo_ip          text,
  ultimo_rssi        integer,
  estado_reportado   text,
  eventos_pendentes  integer not null default 0,
  ultimo_sync_em     timestamptz,
  config             jsonb not null default '{}'::jsonb,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
comment on column public.terminais.device_id is 'ID do hardware (eFuse MAC do ESP32, HEX maiúsculo) — o mesmo exibido no LCD no boot.';

-- Segredo do terminal fica em tabela separada, sem policy nenhuma (ninguém lê via API).
create table public.terminal_credenciais (
  terminal_id    uuid primary key references public.terminais(id),
  chave_hash     text not null,              -- sha256 hex da chave do dispositivo
  gerada_em      timestamptz not null default now(),
  gerada_por     uuid
);

create table public.tipos_embalagem (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique check (codigo ~ '^[A-Z0-9_-]{1,30}$'),
  nome           text not null,
  nome_exibicao  text not null check (char_length(nome_exibicao) between 1 and 16),
  ordem          integer not null default 0,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create table public.produtos (
  id                   uuid primary key default gen_random_uuid(),
  codigo               text not null unique check (codigo ~ '^[A-Z0-9_-]{1,30}$'),
  nome                 text not null,
  nome_exibicao        text not null check (char_length(nome_exibicao) between 1 and 16),
  descricao            text,
  ordem                integer not null default 0,
  ativo                boolean not null default true,
  disponivel_terminal  boolean not null default true,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
comment on table public.produtos is 'Produto/material selecionável no terminal (Laranja, Feijão, Batata...).';

create table public.armazens (
  id                        uuid primary key default gen_random_uuid(),
  codigo                    text not null unique check (codigo ~ '^[A-Z0-9_-]{1,30}$'),
  nome                      text not null,
  local_id                  uuid references public.locais(id),
  permite_estoque_negativo  boolean not null default false,
  ativo                     boolean not null default true,
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now()
);

create table public.itens_estoque (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text not null unique check (codigo ~ '^[A-Z0-9_-]{1,40}$'),
  nome               text not null,
  tipo               public.item_tipo not null,
  unidade            public.unidade_estoque not null,
  produto_id         uuid references public.produtos(id),
  tipo_embalagem_id  uuid references public.tipos_embalagem(id),
  peso_nominal_kg    numeric(12,3) check (peso_nominal_kg is null or peso_nominal_kg > 0),
  ativo              boolean not null default true,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
comment on table public.itens_estoque is 'SKU de estoque: matéria-prima a granel (KG) e produto final embalado (UN). Ex.: FEIJAO-GRANEL, FEIJAO-SC20.';

-- Especificação operacional: produto + peso nominal + tipo de embalagem → de onde sai, para onde entra.
create table public.produto_embalagens (
  id                    uuid primary key default gen_random_uuid(),
  produto_id            uuid not null references public.produtos(id),
  peso_nominal_kg       numeric(12,3) not null check (peso_nominal_kg > 0),
  tipo_embalagem_id     uuid not null references public.tipos_embalagem(id),
  local_id              uuid references public.locais(id),          -- null = vale para todos os locais
  item_origem_id        uuid not null references public.itens_estoque(id),
  armazem_origem_id     uuid not null references public.armazens(id),
  item_destino_id       uuid not null references public.itens_estoque(id),
  armazem_destino_id    uuid not null references public.armazens(id),
  unidades_por_pesagem  numeric(12,3) not null default 1 check (unidades_por_pesagem > 0),
  base_consumo          public.base_consumo not null default 'PESO_LIDO',
  ordem                 integer not null default 0,
  ativo                 boolean not null default true,
  disponivel_terminal   boolean not null default true,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  check (item_origem_id <> item_destino_id),
  constraint ux_produto_embalagem unique nulls not distinct (produto_id, peso_nominal_kg, tipo_embalagem_id, local_id)
);
comment on column public.produto_embalagens.base_consumo is 'Quanto baixar da origem por pesagem válida: PESO_LIDO (peso real) ou PESO_NOMINAL. Definido no cadastro — o sistema não inventa conversão.';
comment on column public.produto_embalagens.unidades_por_pesagem is 'Quantas unidades do item destino entram por pesagem confirmada (1 saco, 1 caixa, 1 palete...).';

create table public.regras_tolerancia (
  id                    uuid primary key default gen_random_uuid(),
  descricao             text,
  produto_embalagem_id  uuid references public.produto_embalagens(id),
  produto_id            uuid references public.produtos(id),
  peso_nominal_kg       numeric(12,3) check (peso_nominal_kg is null or peso_nominal_kg > 0),
  tipo_embalagem_id     uuid references public.tipos_embalagem(id),
  modo                  public.tolerancia_modo not null,
  tolerancia_inferior   numeric(12,4) not null check (tolerancia_inferior >= 0),
  tolerancia_superior   numeric(12,4) not null check (tolerancia_superior >= 0),
  prioridade            integer not null default 0,
  vigencia_inicio       timestamptz not null default now(),
  vigencia_fim          timestamptz,
  ativo                 boolean not null default true,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  check (vigencia_fim is null or vigencia_fim > vigencia_inicio),
  check (modo <> 'PERCENTUAL' or (tolerancia_inferior <= 100 and tolerancia_superior <= 1000))
);
comment on table public.regras_tolerancia is
  'Tolerância por escopo. Todos os campos de escopo nulos = regra global. A mais específica vigente vence '
  '(especificação > produto > peso > embalagem; depois prioridade; depois vigência mais recente). '
  'A regra aplicada é CONGELADA na sessão e em cada pesagem.';

create table public.config_operacao (
  chave          text primary key,
  valor          jsonb not null,
  descricao      text,
  atualizado_em  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
--  SESSÃO DE PESAGEM
-- -----------------------------------------------------------------------------
create table public.sessoes_pesagem (
  id                        uuid primary key default gen_random_uuid(),
  numero                    bigint generated always as identity unique,
  terminal_id               uuid not null references public.terminais(id),
  local_id                  uuid references public.locais(id),
  operador_id               uuid not null references public.operadores(id),
  cartao_id                 uuid not null references public.cartoes_rfid(id),
  cartao_uid                text not null,
  operador_nome             text not null,
  status                    public.sessao_status not null default 'OPERADOR_IDENTIFICADO',

  -- seleções
  produto_id                uuid references public.produtos(id),
  peso_nominal_kg           numeric(12,3),
  tipo_embalagem_id         uuid references public.tipos_embalagem(id),
  produto_embalagem_id      uuid references public.produto_embalagens(id),

  -- snapshot congelado no INICIAR (auditoria histórica)
  regra_tolerancia_id       uuid references public.regras_tolerancia(id),
  tolerancia_modo           public.tolerancia_modo,
  tolerancia_inferior       numeric(12,4),
  tolerancia_superior       numeric(12,4),
  limite_min_kg             numeric(12,3),
  limite_max_kg             numeric(12,3),
  item_origem_id            uuid references public.itens_estoque(id),
  armazem_origem_id         uuid references public.armazens(id),
  item_destino_id           uuid references public.itens_estoque(id),
  armazem_destino_id        uuid references public.armazens(id),
  unidades_por_pesagem      numeric(12,3),
  base_consumo              public.base_consumo,
  snapshot                  jsonb,

  -- linha do tempo
  identificado_em           timestamptz not null,
  operador_confirmado_em    timestamptz,
  produto_selecionado_em    timestamptz,
  peso_selecionado_em       timestamptz,
  embalagem_selecionada_em  timestamptz,
  iniciada_em               timestamptz,
  finalizada_em             timestamptz,
  cancelada_em              timestamptz,
  motivo_encerramento       text,
  encerramento_origem       public.evento_origem,
  encerrado_por             uuid,

  -- totais (recalculados a partir de pesagens/movimentos — nunca digitados)
  qtd_pesagens              integer not null default 0,
  qtd_validas               integer not null default 0,
  qtd_fora_tolerancia       integer not null default 0,
  qtd_rejeitadas            integer not null default 0,
  qtd_canceladas            integer not null default 0,
  unidades_produzidas       numeric(14,3) not null default 0,
  peso_total_lido_kg        numeric(14,3) not null default 0,
  peso_valido_kg            numeric(14,3) not null default 0,
  peso_rejeitado_kg         numeric(14,3) not null default 0,
  estoque_consumido_kg      numeric(14,3) not null default 0,
  duracao_total_seg         numeric generated always as
                              (extract(epoch from (coalesce(finalizada_em, cancelada_em) - identificado_em))) stored,
  duracao_pesagem_seg       numeric generated always as
                              (extract(epoch from (finalizada_em - iniciada_em))) stored,

  origem                    public.evento_origem not null default 'TERMINAL',
  evento_abertura_id        uuid,
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),

  check (limite_min_kg is null or limite_max_kg is null or limite_min_kg <= limite_max_kg),
  check (iniciada_em is null or (
          produto_embalagem_id is not null and limite_min_kg is not null and limite_max_kg is not null
          and item_origem_id is not null and item_destino_id is not null
          and armazem_origem_id is not null and armazem_destino_id is not null
          and unidades_por_pesagem is not null and base_consumo is not null)),
  check (status <> 'PESAGEM_EM_ANDAMENTO' or iniciada_em is not null),
  check (status <> 'FINALIZADA' or (iniciada_em is not null and finalizada_em is not null)),
  check (status <> 'CANCELADA' or (cancelada_em is not null and iniciada_em is null))
);
comment on table public.sessoes_pesagem is 'Uma sessão = um operador, um terminal, um produto/peso/embalagem e a tolerância congelada. Nunca é apagada.';

-- Um terminal e um operador só podem ter UMA sessão aberta por vez.
create unique index ux_sessao_aberta_terminal on public.sessoes_pesagem(terminal_id)
  where status not in ('FINALIZADA', 'CANCELADA');
create unique index ux_sessao_aberta_operador on public.sessoes_pesagem(operador_id)
  where status not in ('FINALIZADA', 'CANCELADA');
create index ix_sessao_operador_data on public.sessoes_pesagem(operador_id, identificado_em desc);
create index ix_sessao_terminal_data on public.sessoes_pesagem(terminal_id, identificado_em desc);
create index ix_sessao_produto_data  on public.sessoes_pesagem(produto_id, iniciada_em desc);
create index ix_sessao_status        on public.sessoes_pesagem(status);

-- -----------------------------------------------------------------------------
--  PESAGENS INDIVIDUAIS
-- -----------------------------------------------------------------------------
create table public.pesagens (
  id                          uuid primary key default gen_random_uuid(),
  sessao_id                   uuid not null references public.sessoes_pesagem(id),
  sequencia                   integer not null check (sequencia > 0),
  sequencia_terminal          integer,
  event_id                    uuid not null unique,     -- evento da LEITURA (idempotência)
  evento_confirmacao_id       uuid unique,              -- evento da CONFIRMAÇÃO (fluxo em 2 passos)
  terminal_id                 uuid not null references public.terminais(id),
  operador_id                 uuid not null references public.operadores(id),
  produto_id                  uuid not null references public.produtos(id),
  produto_embalagem_id        uuid not null references public.produto_embalagens(id),
  tipo_embalagem_id           uuid not null references public.tipos_embalagem(id),
  peso_nominal_kg             numeric(12,3) not null,
  peso_lido                   numeric(12,3) not null,
  unidade                     text not null check (unidade in ('kg', 'g')),
  peso_lido_kg                numeric(12,3) not null,
  regra_tolerancia_id         uuid references public.regras_tolerancia(id),
  tolerancia_modo             public.tolerancia_modo not null,
  tolerancia_inferior         numeric(12,4) not null,
  tolerancia_superior         numeric(12,4) not null,
  limite_min_kg               numeric(12,3) not null,
  limite_max_kg               numeric(12,3) not null,
  resultado                   public.pesagem_resultado not null,
  status                      public.pesagem_status not null,
  contabilizada               boolean not null default false,
  motivo                      text,
  leitura_estavel             boolean,
  lido_em                     timestamptz not null,
  confirmado_em               timestamptz,
  confirmado_por_operador_id  uuid references public.operadores(id),
  registrado_em               timestamptz not null default now(),
  atualizado_em               timestamptz not null default now(),
  origem                      public.evento_origem not null,
  unique (sessao_id, sequencia),
  check (limite_min_kg <= limite_max_kg),
  check (status <> 'CONFIRMADA' or (resultado = 'DENTRO_TOLERANCIA' and contabilizada and confirmado_em is not null)),
  check (not contabilizada or status = 'CONFIRMADA'),
  check (status <> 'DENTRO_TOLERANCIA' or resultado = 'DENTRO_TOLERANCIA'),
  check (status <> 'FORA_TOLERANCIA'   or resultado = 'FORA_TOLERANCIA')
);
comment on table public.pesagens is 'Cada leitura confirmada/rejeitada/fora de tolerância vira uma linha. Inválidas NÃO são apagadas.';
create index ix_pesagem_sessao    on public.pesagens(sessao_id, sequencia);
create index ix_pesagem_operador  on public.pesagens(operador_id, lido_em desc);
create index ix_pesagem_terminal  on public.pesagens(terminal_id, lido_em desc);
create index ix_pesagem_produto   on public.pesagens(produto_id, lido_em desc);
create index ix_pesagem_status    on public.pesagens(status);

-- -----------------------------------------------------------------------------
--  ESTOQUE
-- -----------------------------------------------------------------------------
create table public.estoque_saldos (
  item_id        uuid not null references public.itens_estoque(id),
  armazem_id     uuid not null references public.armazens(id),
  quantidade     numeric(16,3) not null default 0,   -- na unidade do item (KG ou UN)
  peso_kg        numeric(16,3) not null default 0,
  atualizado_em  timestamptz not null default now(),
  primary key (item_id, armazem_id)
);
comment on table public.estoque_saldos is 'Saldo corrente. Só é alterado por public._estoque_lancar (mesma transação do movimento).';
create index ix_saldo_armazem on public.estoque_saldos(armazem_id);

create table public.estoque_movimentos (
  id                     bigint generated always as identity primary key,
  grupo_id               uuid not null,
  tipo                   public.movimento_tipo not null,
  sentido                smallint not null check (sentido in (-1, 1)),
  item_id                uuid not null references public.itens_estoque(id),
  armazem_id             uuid not null references public.armazens(id),
  quantidade             numeric(16,3) not null check (quantidade > 0),
  unidade                public.unidade_estoque not null,
  peso_kg                numeric(16,3) not null check (peso_kg >= 0),
  saldo_quantidade_apos  numeric(16,3) not null,
  saldo_peso_apos        numeric(16,3) not null,
  pesagem_id             uuid references public.pesagens(id),
  sessao_id              uuid references public.sessoes_pesagem(id),
  terminal_id            uuid references public.terminais(id),
  operador_id            uuid references public.operadores(id),
  usuario_id             uuid,
  origem                 public.evento_origem not null,
  event_id               uuid,
  observacao             text,
  ocorrido_em            timestamptz not null,
  registrado_em          timestamptz not null default now(),
  check (tipo not in ('SAIDA_CONSUMO_PESAGEM', 'ENTRADA_PRODUCAO_PESAGEM') or pesagem_id is not null),
  check (tipo <> 'SAIDA_CONSUMO_PESAGEM'    or sentido = -1),
  check (tipo <> 'ENTRADA_PRODUCAO_PESAGEM' or sentido =  1),
  check (tipo <> 'ENTRADA_MANUAL'           or sentido =  1),
  check (tipo <> 'SAIDA_MANUAL'             or sentido = -1)
);
comment on table public.estoque_movimentos is 'Razão (ledger) imutável. Cada pesagem válida confirmada gera exatamente 1 saída + 1 entrada.';
-- Garantia física contra dupla movimentação da mesma pesagem (retry, sync, concorrência):
create unique index ux_mov_pesagem_tipo on public.estoque_movimentos(pesagem_id, tipo) where pesagem_id is not null;
-- Idempotência de lançamentos manuais:
create unique index ux_mov_manual_evento on public.estoque_movimentos(event_id) where pesagem_id is null and event_id is not null;
create index ix_mov_item_armazem on public.estoque_movimentos(item_id, armazem_id, ocorrido_em desc);
create index ix_mov_sessao       on public.estoque_movimentos(sessao_id);
create index ix_mov_data         on public.estoque_movimentos(ocorrido_em desc);

-- -----------------------------------------------------------------------------
--  LOG / AUDITORIA
-- -----------------------------------------------------------------------------
-- Inbox idempotente: todo evento do terminal é processado UMA vez; o retry recebe a mesma resposta.
create table public.terminal_eventos (
  event_id      uuid primary key,
  terminal_id   uuid not null references public.terminais(id),
  tipo          text not null,
  dados         jsonb not null,
  dados_hash    text not null,
  ocorrido_em   timestamptz,
  recebido_em   timestamptz not null default now(),
  origem        public.evento_origem not null,
  ok            boolean not null,
  codigo        text,
  resposta      jsonb not null,
  sessao_id     uuid,
  pesagem_id    uuid
);
create index ix_evt_terminal_data on public.terminal_eventos(terminal_id, recebido_em desc);
create index ix_evt_sessao        on public.terminal_eventos(sessao_id);

create table public.auditoria_eventos (
  id              bigint generated always as identity primary key,
  ocorrido_em     timestamptz not null default now(),
  registrado_em   timestamptz not null default now(),
  origem          public.evento_origem not null,
  acao            text not null,
  entidade        text,
  entidade_id     text,
  usuario_id      uuid,
  operador_id     uuid,
  terminal_id     uuid,
  sessao_id       uuid,
  pesagem_id      uuid,
  event_id        uuid,
  valor_anterior  jsonb,
  valor_novo      jsonb,
  detalhes        jsonb
);
create index ix_aud_data      on public.auditoria_eventos(ocorrido_em desc);
create index ix_aud_acao      on public.auditoria_eventos(acao, ocorrido_em desc);
create index ix_aud_terminal  on public.auditoria_eventos(terminal_id, ocorrido_em desc);
create index ix_aud_sessao    on public.auditoria_eventos(sessao_id);
create index ix_aud_entidade  on public.auditoria_eventos(entidade, entidade_id);

-- FKs sem índice (evita seq scan em deletes/joins) -----------------------------
create index ix_operadores_local     on public.operadores(local_id);
create index ix_terminais_local      on public.terminais(local_id);
create index ix_armazens_local       on public.armazens(local_id);
create index ix_itens_produto        on public.itens_estoque(produto_id);
create index ix_itens_tipo_emb       on public.itens_estoque(tipo_embalagem_id);
create index ix_pe_tipo_emb          on public.produto_embalagens(tipo_embalagem_id);
create index ix_pe_local             on public.produto_embalagens(local_id);
create index ix_pe_item_origem       on public.produto_embalagens(item_origem_id);
create index ix_pe_item_destino      on public.produto_embalagens(item_destino_id);
create index ix_pe_arm_origem        on public.produto_embalagens(armazem_origem_id);
create index ix_pe_arm_destino       on public.produto_embalagens(armazem_destino_id);
create index ix_rt_pe                on public.regras_tolerancia(produto_embalagem_id);
create index ix_rt_produto           on public.regras_tolerancia(produto_id);
create index ix_rt_tipo_emb          on public.regras_tolerancia(tipo_embalagem_id);
create index ix_sessao_local         on public.sessoes_pesagem(local_id);
create index ix_sessao_cartao        on public.sessoes_pesagem(cartao_id);
create index ix_sessao_pe            on public.sessoes_pesagem(produto_embalagem_id);
create index ix_sessao_regra         on public.sessoes_pesagem(regra_tolerancia_id);
create index ix_sessao_tipo_emb      on public.sessoes_pesagem(tipo_embalagem_id);
create index ix_sessao_item_origem   on public.sessoes_pesagem(item_origem_id);
create index ix_sessao_item_destino  on public.sessoes_pesagem(item_destino_id);
create index ix_sessao_arm_origem    on public.sessoes_pesagem(armazem_origem_id);
create index ix_sessao_arm_destino   on public.sessoes_pesagem(armazem_destino_id);
create index ix_pesagem_pe           on public.pesagens(produto_embalagem_id);
create index ix_pesagem_tipo_emb     on public.pesagens(tipo_embalagem_id);
create index ix_pesagem_regra        on public.pesagens(regra_tolerancia_id);
create index ix_pesagem_conf_por     on public.pesagens(confirmado_por_operador_id);
create index ix_mov_armazem          on public.estoque_movimentos(armazem_id);
create index ix_mov_terminal         on public.estoque_movimentos(terminal_id);
create index ix_mov_operador         on public.estoque_movimentos(operador_id);

-- -----------------------------------------------------------------------------
--  CONFIGURAÇÕES PADRÃO
-- -----------------------------------------------------------------------------
insert into public.config_operacao (chave, valor, descricao) values
  ('terminal_offline_apos_seg', '120'::jsonb, 'Sem heartbeat por mais que isso = terminal OFFLINE.'),
  ('heartbeat_intervalo_seg',   '30'::jsonb,  'Intervalo de heartbeat sugerido ao firmware.'),
  ('sync_lote_max',             '50'::jsonb,  'Máximo de eventos por chamada de terminal_sincronizar.'),
  ('peso_maximo_leitura_kg',    '5000'::jsonb,'Leituras acima disso são recusadas como inválidas (proteção contra lixo serial).'),
  ('fuso_horario',              '"America/Sao_Paulo"'::jsonb, 'Fuso usado nas views de produção diária.');
