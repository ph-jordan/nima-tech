# Sistema de Pesagem — Supabase (backend transacional) + ESP32 (terminal)

Pacote pronto para aplicar num **projeto Supabase novo**. O ESP32 vira só o terminal operacional: lê RFID, botões e balança e manda eventos. O Supabase valida o cartão, aplica a tolerância, movimenta o estoque, registra auditoria e garante que nada se duplica.

```
Sistema_Pesagem_Supabase/
├── supabase/
│   ├── migrations/            ← aplicar nesta ordem (01 → 06)
│   │   ├── …_01_schema.sql                      enums, tabelas, índices, constraints
│   │   ├── …_02_triggers_e_funcoes_internas.sql máquinas de estado, auditoria, estoque
│   │   ├── …_03_api_terminal.sql                RPCs do ESP32 + CONFIRMAR_PESAGEM
│   │   ├── …_04_api_admin.sql                   RPCs do APP/WEB (terminal, cartão, estoque)
│   │   ├── …_05_rls_e_permissoes.sql            RLS, policies, GRANT/REVOKE
│   │   └── …_06_views_indicadores.sql           views de relatório/dashboard
│   ├── seed_exemplo.sql       ← dados de exemplo (opcional)
│   └── tests/
│       ├── pesagem_tests.sql        89 asserções (23 cenários + segurança)
│       └── concorrencia_test.sh     conexões simultâneas (2 terminais + retry em rajada)
├── firmware/Terminal_Pesagem_Supabase/Terminal_Pesagem_Supabase.ino   ← firmware v4
├── tools/simulador_terminal.py   ← testa a API como se fosse a placa (sem hardware)
└── local_test/                    ← roda tudo num Postgres local (dev)
```

---

## Diagnóstico

**O "404 / NAO RECONHECIDO" do `Codigo_404.ino` não é defeito da placa.** No estado `STATE_CARD_AUTH` a placa faz `GET http://212.85.19.168:3000/api/v1/placa/pesagem/<UID>` e, quando a API antiga devolve 404, o LCD mostra "NAO RECONHECIDO". Ou seja, a placa leu o cartão e chegou ao servidor, mas aquela API não encontrou o UID. Dois agravantes:

- o UID era enviado em **decimal** (bytes concatenados), formato que dificilmente bate com o que é cadastrado. O firmware novo envia em **HEX** (ex.: `A1B2C3D4`), que é o formato usado no banco;
- a API usava HTTP sem TLS e autenticação por cookie. No firmware novo isso foi substituído por HTTPS + chave por dispositivo.

**Banco.** Os dois projetos Supabase da conta (*Phocus4*: venda de fotos; *nPly.*: BI/dashboards) não têm nenhuma estrutura de pesagem, estoque, RFID ou terminal. Por isso:

- **A) Reaproveitado:** nada do Supabase. Do ecossistema foram mantidos `auth.users` (login do APP/WEB), o fluxo de telas da placa, a camada serial da balança da v3 (já validada), os pinos da PCI e o portal Wi-Fi.
- **B) Criado:** todo o modelo abaixo.
- **C) Alterado:** nenhuma tabela existente. Num projeto novo, as migrations não mexem em nada já existente.

---

## D) Modelo de dados

```mermaid
erDiagram
  operadores ||--o{ cartoes_rfid_vinculos : "histórico"
  cartoes_rfid ||--o{ cartoes_rfid_vinculos : ""
  locais ||--o{ terminais : ""
  terminais ||--|| terminal_credenciais : "chave (hash)"
  produtos ||--o{ produto_embalagens : "peso × embalagem"
  tipos_embalagem ||--o{ produto_embalagens : ""
  itens_estoque ||--o{ produto_embalagens : "origem / destino"
  armazens ||--o{ produto_embalagens : "origem / destino"
  regras_tolerancia }o--o| produto_embalagens : "escopo"
  terminais ||--o{ sessoes_pesagem : ""
  operadores ||--o{ sessoes_pesagem : ""
  produto_embalagens ||--o{ sessoes_pesagem : "snapshot congelado"
  sessoes_pesagem ||--o{ pesagens : ""
  pesagens ||--o{ estoque_movimentos : "1 saída + 1 entrada"
  itens_estoque ||--o{ estoque_saldos : ""
  armazens ||--o{ estoque_saldos : ""
  terminais ||--o{ terminal_eventos : "inbox idempotente"
```

| Camada | Tabelas |
|---|---|
| Cadastro | `locais`, `operadores`, `cartoes_rfid`, `cartoes_rfid_vinculos`, `terminais`, `terminal_credenciais`, `produtos`, `tipos_embalagem`, `armazens`, `itens_estoque`, `produto_embalagens`, `regras_tolerancia`, `config_operacao`, `perfis` |
| Sessão | `sessoes_pesagem` |
| Pesagem | `pesagens` |
| Estoque | `estoque_saldos` (saldo corrente), `estoque_movimentos` (razão imutável) |
| Log/Auditoria | `terminal_eventos` (todo evento da placa + resposta), `auditoria_eventos` (quem, quando, onde, valor anterior/novo) |

**Como o cadastro vira operação.** Uma linha de `produto_embalagens` = *Feijão + 20 kg + Saco* → baixa `FEIJAO-GRANEL` do armazém `MP` e dá entrada em `FEIJAO-SC20` no armazém `PA`. A especificação também define `unidades_por_pesagem` (1 saco, 1 caixa, 1 palete…) e `base_consumo`, que diz se a baixa é pelo **peso lido** ou pelo **peso nominal**. Essa regra vem do cadastro, o sistema não inventa conversão.

**Tolerância.** `regras_tolerancia` aceita escopo global, por produto, por peso, por embalagem ou por especificação, em kg absoluto ou %, com limites inferior e superior separados e vigência. Vence a regra mais específica. No **INICIAR PESAGEM**, a regra, os limites, a origem e o destino ficam **congelados** na sessão e são copiados em cada pesagem. Mudar a regra depois não altera nenhuma pesagem já feita (há teste para isso).

**Estados** (transições inválidas são barradas por trigger, inclusive em UPDATE direto):

- Sessão: `OPERADOR_IDENTIFICADO → SELECIONANDO_PRODUTO ⇄ SELECIONANDO_PESO ⇄ SELECIONANDO_EMBALAGEM ⇄ PRONTO_PARA_INICIAR → PESAGEM_EM_ANDAMENTO → FINALIZADA`. `CANCELADA` só é possível antes de `PESAGEM_EM_ANDAMENTO`. `FINALIZADA` e `CANCELADA` são estados finais.
- Pesagem: `REGISTRADA → DENTRO_TOLERANCIA → CONFIRMADA | REJEITADA | CANCELADA`; `FORA_TOLERANCIA` nunca contabiliza. Estados finais são imutáveis, e o peso medido nunca muda.
- Nada operacional pode ser apagado: há trigger que bloqueia DELETE e TRUNCATE.

---

## E–F) Migrations e RPCs

### API do terminal (ESP32 → `POST https://<ref>.supabase.co/rest/v1/rpc/<fn>`)

Cabeçalhos: `apikey: <publishable ou anon key>`, `x-device-id: <ID do chip>`, `x-device-key: <chave do terminal>`

| RPC | Corpo |
|---|---|
| `terminal_heartbeat` | `{"p_dados":{"firmware_versao","estado","eventos_pendentes","ip","rssi"}}`. Devolve a sessão aberta, usada para retomar após reboot |
| `terminal_catalogo` | `{}` → produtos › pesos › embalagens + limites |
| `terminal_evento` | `{"p_tipo","p_event_id","p_dados"}` |
| `terminal_sincronizar` | `{"p_eventos":[{"tipo","event_id","dados"},…]}`: fila do microSD, processada em ordem |

Tipos de evento: `IDENTIFICAR_CARTAO`, `CONFIRMAR_OPERADOR`, `SELECIONAR_PRODUTO`, `SELECIONAR_PESO`, `SELECIONAR_EMBALAGEM`, `INICIAR_PESAGEM`, `CANCELAR_SESSAO`, **`CONFIRMAR_PESAGEM`**, `REGISTRAR_LEITURA` + `REJEITAR_PESAGEM` (fluxo em 2 passos, para o APP), `FINALIZAR_SESSAO`, `LOG`.

**`CONFIRMAR_PESAGEM` (requisito 28), numa transação só:** autentica o terminal → trava o evento (advisory lock) → se o `event_id` já existe, devolve a mesma resposta (`replay`) → trava a sessão (`FOR UPDATE`) → exige `PESAGEM_EM_ANDAMENTO` e operador válido → grava a pesagem com a tolerância congelada → se estiver dentro, marca `CONFIRMADA` e gera saída da origem + entrada do destino (o saldo é atualizado com lock de linha); se a origem não tiver saldo, a pesagem vira `REJEITADA` e o estoque não muda → se estiver fora, registra sem tocar no estoque → recalcula os totais da sessão → audita → grava a resposta no inbox.

**Resposta:** HTTP 200 significa "processado". Se `ok=false` é recusa de negócio, que fica gravada e não adianta reenviar. Qualquer erro HTTP ou timeout significa que nada foi gravado: a placa reenvia **o mesmo `event_id` com o mesmo JSON**.

### Idempotência — quatro camadas

1. `terminal_eventos.event_id` como PK: o primeiro processamento grava a resposta e os reenvios recebem `replay:true`.
2. `pg_advisory_xact_lock(event_id)`: 15 envios simultâneos do mesmo evento geram **1** pesagem (testado).
3. `pesagens.event_id UNIQUE` e `estoque_movimentos (pesagem_id, tipo) UNIQUE`: barreira física contra movimento duplicado.
4. Mesmo `event_id` com dados diferentes → `EVENT_ID_CONFLITO`.

### API administrativa (APP/WEB autenticado)

`admin_terminal_registrar(device_id, nome, local_id, localizacao)` → devolve a **chave do terminal uma única vez** · `admin_terminal_alterar_status` · `admin_cartao_vincular(uid, operador_id, motivo)` (troca de dono mantém o histórico) · `admin_cartao_desvincular` · `admin_cartao_alterar_status` · `admin_estoque_lancar(event_id, tipo, item, armazém, qtd…)` (entrada, saída e ajuste idempotentes) · `admin_sessao_encerrar(sessao_id, motivo)` (supervisor fecha sessão abandonada).

Os cadastros simples (produtos, embalagens, tolerâncias, operadores…) o APP grava direto nas tabelas, com RLS.

### Views para APP/WEB e relatórios

`vw_sessoes_resumo` (inclui taxa de aprovação, peso médio e unidades/hora) · `vw_pesagens_detalhe` (quem, quando, onde, tolerância, desvio e movimentos) · `vw_estoque_saldos` · `vw_terminais_status` (online/offline pelo heartbeat) · `vw_producao_diaria` · `vw_produtividade_operador` · `vw_estoque_movimento_diario`.

---

## G) Segurança / RLS

| Quem | Acesso |
|---|---|
| **ESP32** (`anon` + chave do dispositivo) | nenhuma tabela; só `terminal_*`. A chave é guardada como hash SHA-256 em tabela sem policy |
| **ADMIN** | todos os cadastros, terminais, configurações e perfis |
| **SUPERVISOR** | cadastros operacionais, cartões, ajustes de estoque, encerrar sessão; lê tudo |
| **LEITURA** | lê produção, estoque e cadastros (dashboards) |
| **OPERADOR** | lê cadastros e estoque, e apenas as **próprias** sessões e pesagens |
| todos | ninguém faz INSERT/UPDATE/DELETE em sessões, pesagens, movimentos, saldos ou auditoria. Só as funções escrevem |

Usuário novo do Auth nasce com `perfis.ativo = false` e não vê nada até um ADMIN liberar. Ninguém consegue se autopromover.

---

## H) Testes

Executados num Postgres 16 local com PostgREST 12, o mesmo componente que o Supabase usa para expor as RPCs:

- `pesagem_tests.sql`: **89 asserções, todas OK**. Cobrem os 23 cenários pedidos (RFID válido e inválido, confirma e não confirma, seleções, cancelar antes e depois, dentro e fora da tolerância, contabilizar inválida, estoque, finalização, retry, evento duplicado, sessão finalizada, alterar pesagem confirmada, múltiplas pesagens, concorrência, offline + sync), além de tolerância congelada, estoque insuficiente, tolerância percentual e RLS por papel.
- `concorrencia_test.sh`: 40 pesagens em paralelo em 2 terminais sobre o mesmo estoque, mais 15 cópias simultâneas do mesmo evento. O saldo fecha com o razão, sai exatamente 1 pesagem do evento repetido e a sequência fica sem buracos.
- `simulador_terminal.py`: o mesmo protocolo HTTP do firmware, ponta a ponta (headers, 401 para chave errada, replay pela fila). **Tudo OK.**

O firmware passou por checagem de sintaxe C++ contra o ArduinoJson 7.4.2 real. **Não foi compilado para o ESP32**, porque o sandbox não alcança os servidores da Espressif. Compile na Arduino IDE antes de gravar.

---

## Como colocar no ar (projeto Supabase novo)

1. **Banco.** No SQL Editor, rode as 6 migrations em ordem (ou `supabase db push` com a pasta `supabase/`). Opcional: `seed_exemplo.sql`. Para testar, use uma *branch* ou um projeto de teste e rode `pesagem_tests.sql`, porque os testes criam dados e nada é apagável.
2. **Primeiro admin.** Crie o usuário em Authentication e rode:
   `update public.perfis set papel='ADMIN', ativo=true where email='seu@email';`
3. **Terminal.** Ligue a placa: o LCD mostra o **ID PLACA** (ex.: `A4CF12B3C4D5`). Logado como admin no APP ou no SQL, rode:
   `select public.admin_terminal_registrar('A4CF12B3C4D5', 'Balança 01', <local_id>, 'Linha 1');`
   e **guarde a `chave`**.
4. **Placa.** Troque o placeholder de `AP_PASSWORD` no firmware por uma senha própria antes de compilar. Ligue segurando **CANCELAR** e conecte-se à rede `ESP32-Pesagem` (senha definida em `AP_PASSWORD`, endereço 192.168.4.1). Preencha Wi-Fi, **Supabase URL**, **API key** (Settings › API: publishable ou anon) e **Chave do terminal**.
5. **Cartões.** Rode `admin_cartao_vincular('<UID HEX>', <operador_id>)`. O UID aparece no LCD ao aproximar o cartão.
6. **Validar sem a placa:**
   `python3 tools/simulador_terminal.py --url https://<ref>.supabase.co --apikey <key> --device <ID> --key <chave> --uid <UID>`

## Teste 100% local (sem projeto Supabase na nuvem)

Pré-requisitos no PC (Windows): **Docker Desktop**, **Node.js** e **Python 3**.

```powershell
cd Sistema_Pesagem_Supabase
npx supabase init                      # cria supabase/config.toml (responda "N" às perguntas)
npx supabase start                     # sobe Postgres+PostgREST+Auth locais e aplica as 6 migrations
npx supabase db reset                  # (re)aplica migrations do zero quando quiser recomeçar
```

`supabase start` mostra a **API URL** (`http://127.0.0.1:54321`), a **anon/publishable key** e a **DB URL** (`postgresql://postgres:postgres@127.0.0.1:54322/postgres`).

1. Dados de exemplo + terminal de teste (Studio local em http://127.0.0.1:54323 › SQL Editor, ou `psql "<DB URL>" -f ...`):
   rode `supabase/seed_exemplo.sql` e depois
   `select public.admin_terminal_registrar` não funciona no SQL Editor (exige usuário ADMIN logado); para teste local use:
   ```sql
   insert into public.terminais (device_id, nome) values ('<ID PLACA>', 'Balanca teste');
   insert into public.terminal_credenciais (terminal_id, chave_hash)
   select id, encode(extensions.digest('chave-local-123','sha256'),'hex') from public.terminais where device_id = '<ID PLACA>';
   ```
2. **Sem a placa:** `python tools/simulador_terminal.py --url http://127.0.0.1:54321 --apikey <anon key> --device <ID PLACA> --key chave-local-123 --uid A1B2C3D4`
3. **Com a placa:** no portal Wi-Fi use **Supabase URL = `http://<IP do PC na rede>:54321`** (ex.: `http://192.168.0.15:54321`, veja com `ipconfig`), a anon key local e `chave-local-123`. O firmware usa HTTP simples quando a URL começa com `http://`. Libere a porta 54321 no Firewall do Windows. PC e ESP32 precisam estar na mesma rede Wi-Fi.
4. Testes SQL: `psql "<DB URL>" -f supabase/tests/pesagem_tests.sql` (num banco recém-resetado + seed).

## Hardware / firmware

- **microSD:** não aparece no esquemático v1.0. O firmware usa o mesmo SPI do RC522 (SCK 18, MISO 19, MOSI 23) com **CS = GPIO 33** (`PIN_SD_CS`). Ajuste se ligar em outro pino. Sem cartão SD o terminal funciona online e, se a rede cair no meio, guarda a pesagem em RAM e pede para confirmar de novo (mesmo `event_id`).
- **Offline:** pesagem e finalização são gravadas no SD *antes* do envio (write-ahead) e sincronizadas em ordem quando a rede volta. **A identificação por RFID exige conexão** (Regra 1: só o servidor valida o cartão). O banco já aceita sessões criadas offline (`sessao_id` gerado na placa + validade do cartão na data do evento), caso isso seja liberado no futuro.
- **Reboot no meio da pesagem:** a placa pergunta ao servidor (heartbeat) se há sessão aberta e retoma. Offline, retoma pela cópia salva na NVS.
- **Arduino IDE:** placa "ESP32 Dev Module", partição **Huge APP**. Bibliotecas: hd44780, MFRC522, WiFiManager (tzapu), ArduinoJson 7.

## Pontos para decidir / pendências

1. **TLS:** o firmware usa `setInsecure()` (cifra, mas não valida o certificado). Para produção, fixar a CA raiz do `*.supabase.co` com `tls.setCACert(...)`.
2. **MQTT/HiveMQ removido:** o status online/offline agora está em `vw_terminais_status`, e as senhas que estavam fixas no código saíram. Se algum sistema ainda lê o tópico `balanca/status`, dá para reativar.
3. **Estoque negativo:** padrão `permite_estoque_negativo = false`. Sem saldo de matéria-prima, a pesagem vira `REJEITADA`. Se a entrada de matéria-prima for lançada com atraso na planta, ligue a opção no armazém.
4. **Baixa da origem:** o seed usa `PESO_LIDO` (o peso real que saiu do granel). Troque para `PESO_NOMINAL` por especificação, se for o critério da empresa.
5. **Cartões antigos** cadastrados com UID decimal na API anterior precisam ser recadastrados em HEX.
6. Funções criadas no futuro no schema `public` recebem EXECUTE para `anon` por padrão no Supabase. Revogue nas novas funções internas.
