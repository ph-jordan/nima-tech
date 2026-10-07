// ============================================================================
//  TERMINAL DE PESAGEM INDUSTRIAL - ESP32  |  Firmware v4 (Supabase)
// ----------------------------------------------------------------------------
//  O que mudou em relação à v3 (Codigo_404):
//   * A API antiga (http://212.85.19.168:3000, que devolvia 404 "NAO
//     RECONHECIDO") foi substituída pelo Supabase, via HTTPS + RPC:
//       terminal_heartbeat / terminal_catalogo / terminal_evento / terminal_sincronizar
//   * Todo o cadastro (operadores, cartões, produtos, pesos, embalagens,
//     tolerâncias, armazéns) vem do banco. Nada fixo no firmware.
//   * Cada ação gera um EVENTO com UUID (event_id). Reenviar o mesmo evento
//     nunca duplica pesagem nem estoque (o servidor responde "replay").
//   * Pesagens e finalização são gravadas ANTES no microSD (write-ahead).
//     Sem Wi-Fi, ficam na fila /fila e são sincronizadas em ordem depois.
//   * Quem decide se a pesagem é válida e movimenta estoque é o SERVIDOR,
//     usando a tolerância congelada na sessão. O LCD mostra uma prévia local.
//   * CANCELAR só funciona antes de INICIAR PESAGEM. Depois, só FINALIZAR.
//   * Camada serial da balança: idêntica à v3 (já validada em campo).
//   * MQTT/HiveMQ removido (status online/offline agora é o heartbeat no
//     Supabase → view vw_terminais_status) e sem senhas fixas no código.
//
//  Bibliotecas: hd44780, MFRC522, WiFiManager (tzapu), ArduinoJson v7.
//  Placa: "ESP32 Dev Module". Partition scheme: "Huge APP (3MB No OTA)" se o
//  sketch não couber no padrão (TLS + WiFiManager ocupam bastante flash).
//
//  CONFIGURAÇÃO (portal Wi-Fi "ESP32-Pesagem"):
//   - Supabase URL ........ https://<ref>.supabase.co
//   - Supabase API key .... publishable key (sb_publishable_...) ou anon key
//   - Chave do terminal ... devolvida UMA vez por admin_terminal_registrar()
//  Para reabrir o portal: ligar a placa segurando CANCELAR.
// ============================================================================

#include <Wire.h>
#include <hd44780.h>
#include <hd44780ioClass/hd44780_I2Cexp.h>
#include <SPI.h>
#include <MFRC522.h>
#include <SD.h>
#include <HardwareSerial.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include "time.h"
#if __has_include("esp_random.h")
#include "esp_random.h"   // core 3.x (IDF 5)
#else
#include "esp_system.h"   // core 2.x
#endif

#define FW_VERSION   "4.0.0"
#define DEBUG_SCALE  false   // true = imprime bytes da balança em HEX (diagnóstico)
#define DEBUG_HTTP   true    // imprime requisições/respostas no Monitor Serial (115200)

// ---------------------------------------------------------------------------
// 1. HARDWARE (mesmos pinos da PCI v1.0; microSD no barramento SPI do RC522)
// ---------------------------------------------------------------------------
#define PIN_I2C_SDA 21
#define PIN_I2C_SCL 22
#define LCD_ADDR_MAIN 0x27
#define LCD_ADDR_SEC  0x26
#define PIN_RFID_SS   5
#define PIN_SPI_SCK   18
#define PIN_SPI_MISO  19
#define PIN_SPI_MOSI  23
#define PIN_RFID_RST  4
#define PIN_SD_CS     33   // <<< microSD: não está no esquemático v1.0. Ajuste se ligar em outro pino livre.
#define PIN_SCALE_RX  17
#define PIN_SCALE_TX  16
#define PIN_BTN_CONFIRMAR  25
#define PIN_BTN_CANCELAR   26
#define PIN_BTN_FINALIZAR  27
#define PIN_BTN_SETA_CIMA  14
#define PIN_BTN_SETA_BAIXO 32
#define PIN_LED_VERDE    12
#define PIN_LED_VERMELHO 13

// ---------------------------------------------------------------------------
// 2. OBJETOS E CONFIGURAÇÃO
// ---------------------------------------------------------------------------
hd44780_I2Cexp lcd_main(LCD_ADDR_MAIN);
hd44780_I2Cexp lcd_sec(LCD_ADDR_SEC);
MFRC522 rfid(PIN_RFID_SS, PIN_RFID_RST);
HardwareSerial ScaleSerial(2);
Preferences prefs;
WiFiClientSecure tls;
WiFiClient plain;                 // só para testes em rede local (URL http://IP:54321)

const char* AP_NAME = "ESP32-Pesagem";
const char* AP_PASSWORD = "ALTERE_ANTES_DE_USAR"; // troque antes de compilar
const char* NTP_1 = "pool.ntp.org";
const char* NTP_2 = "time.google.com";
const unsigned long HEARTBEAT_MS = 30000;
const unsigned long SYNC_RETRY_MS = 10000;
const int SYNC_LOTE = 10;                          // eventos por chamada de sincronização
const int MAX_TENTATIVAS_EVENTO = 20;              // depois disso o evento vai para /falhas

struct Config { String url; String apikey; String devkey; } cfg;
String deviceId;
bool sdOk = false;

// ---------------------------------------------------------------------------
// 3. ESTADO DA APLICAÇÃO
// ---------------------------------------------------------------------------
enum Estado {
  ST_AGUARDANDO_RFID, ST_CONFIRMAR_OPERADOR, ST_SEL_PRODUTO, ST_SEL_PESO, ST_SEL_EMBALAGEM,
  ST_CONFIRMAR_INICIO, ST_PESAGEM, ST_RESULTADO, ST_REMOVER_PESO, ST_MENSAGEM
};
Estado estado = ST_AGUARDANDO_RFID;
Estado estadoAposMensagem = ST_AGUARDANDO_RFID;
bool redesenhar = true;
unsigned long mensagemAte = 0;

// Sessão corrente (persistida na NVS para sobreviver a reboot)
struct Sessao {
  bool ativa = false;          // true = PESAGEM_EM_ANDAMENTO
  String id;
  String operador;
  String produto;
  String embalagem;
  float nominal = 0, minKg = 0, maxKg = 0;
  int validas = 0, fora = 0, rejeitadas = 0, seq = 0;
  float kgValido = 0;
} S;

String sessaoIdPreInicio;      // sessão ainda não iniciada (identificação/seleções)
String operadorNome;
JsonDocument catalogo;         // { produtos: [ {id,nome,pesos:[{peso_kg,embalagens:[{id,nome,limite_min_kg,limite_max_kg}]}]} ] }
int idxProd = 0, idxPeso = 0, idxEmb = 0;
float previaMin = 0, previaMax = 0;

// Resultado da última pesagem (para a tela de resultado)
String ultimoCodigo;
float ultimoPeso = 0;
bool ultimoPendente = false;

// Evento pendente em RAM (somente quando não há microSD e o envio falhou)
struct Evento { String tipo; String id; String dados; };
Evento eventoRam;
bool temEventoRam = false;

unsigned long ultimoHeartbeat = 0;
unsigned long ultimoSync = 0;
int falhasCabecaFila = 0;

// ---------------------------------------------------------------------------
// 4. LCD / LEDs / BOTÕES
// ---------------------------------------------------------------------------
String fit16(const String& s) {
  String r = s.substring(0, 16);
  while (r.length() < 16) r += ' ';
  return r;
}
void lcdMain(const String& l1, const String& l2) {
  lcd_main.setCursor(0, 0); lcd_main.print(fit16(l1));
  lcd_main.setCursor(0, 1); lcd_main.print(fit16(l2));
}
void lcdSec(const String& l1, const String& l2) {
  lcd_sec.setCursor(0, 0); lcd_sec.print(fit16(l1));
  lcd_sec.setCursor(0, 1); lcd_sec.print(fit16(l2));
}
void setLeds(bool verde, bool vermelho) {
  digitalWrite(PIN_LED_VERDE, verde ? HIGH : LOW);
  digitalWrite(PIN_LED_VERMELHO, vermelho ? HIGH : LOW);
}

struct Botao { uint8_t pin; bool nivel; unsigned long t; bool clicou; };
Botao bConf = {PIN_BTN_CONFIRMAR, false, 0, false};
Botao bCanc = {PIN_BTN_CANCELAR, false, 0, false};
Botao bFim  = {PIN_BTN_FINALIZAR, false, 0, false};
Botao bCima = {PIN_BTN_SETA_CIMA, false, 0, false};
Botao bBaixo = {PIN_BTN_SETA_BAIXO, false, 0, false};

void lerBotao(Botao& b) {          // detecção de borda com debounce de 40 ms
  bool agora = digitalRead(b.pin) == LOW;
  b.clicou = false;
  if (agora != b.nivel && millis() - b.t > 40) {
    b.t = millis();
    b.nivel = agora;
    if (agora) b.clicou = true;
  }
}
void lerBotoes() { lerBotao(bConf); lerBotao(bCanc); lerBotao(bFim); lerBotao(bCima); lerBotao(bBaixo); }

void irPara(Estado e) { estado = e; redesenhar = true; }
void mensagem(const String& l1, const String& l2, unsigned long ms, Estado depois, bool erro = true) {
  lcdMain(l1, l2);
  setLeds(!erro, erro);
  mensagemAte = millis() + ms;
  estadoAposMensagem = depois;
  estado = ST_MENSAGEM;
}

// ---------------------------------------------------------------------------
// 5. UTILITÁRIOS: ID, UUID, HORA
// ---------------------------------------------------------------------------
String getChipID() {
  uint64_t chipid = ESP.getEfuseMac();
  char s[13];
  snprintf(s, sizeof(s), "%04X%08X", (uint16_t)(chipid >> 32), (uint32_t)chipid);
  return String(s);
}

String uuid4() {                    // UUID v4 com o gerador de hardware do ESP32
  uint8_t b[16];
  esp_fill_random(b, sizeof(b));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  char s[37];
  snprintf(s, sizeof(s), "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
  return String(s);
}

bool horaValida() { time_t n; time(&n); return n > 1704067200; }   // > 2024-01-01

// ISO-8601 UTC de um instante medido em millis(); "" se o relógio ainda não sincronizou (servidor usa a hora dele)
String isoDeMillis(unsigned long ms) {
  if (!horaValida()) return "";
  time_t n; time(&n);
  n -= (time_t)((millis() - ms) / 1000UL);
  struct tm t; gmtime_r(&n, &t);
  char b[25]; strftime(b, sizeof(b), "%Y-%m-%dT%H:%M:%SZ", &t);
  return String(b);
}
String isoAgora() { return isoDeMillis(millis()); }

String readRFID() {                 // UID em HEX maiúsculo (formato cadastrado no banco)
  if (rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
    String uid;
    for (byte i = 0; i < rfid.uid.size; i++) {
      if (rfid.uid.uidByte[i] < 0x10) uid += '0';
      uid += String(rfid.uid.uidByte[i], HEX);
    }
    rfid.PICC_HaltA();
    rfid.PCD_StopCrypto1();
    uid.toUpperCase();
    return uid;
  }
  return "";
}

// ============================================================================
// 6. CAMADA SERIAL DA BALANÇA (igual à v3)
// ============================================================================
String scaleRxBuf = "";
unsigned long lastByteRxMs = 0;
unsigned long lastPollMs = 0;
float lastValidWeight = NAN;
unsigned long lastWeightMs = 0;
int last_baud_idx = -1;
int last_cmd_idx = -1;
float estabRef = NAN;               // controle de estabilidade (informativo)
unsigned long estabDesdeMs = 0;

struct SerialOption { long baud; uint32_t config; const char* label; };
const char* pollingCommands[] = {"P\r\n", "\x05", "P\r", "W\r\n", "READ\r\n", "\r\n", "P", "W"};
const int numPollCommands = 8;
SerialOption scaleOptions[] = {
  {9600, SERIAL_8N1, "9600 8N1"}, {9600, SERIAL_7E1, "9600 7E1"},
  {4800, SERIAL_8N1, "4800 8N1"}, {4800, SERIAL_7E1, "4800 7E1"},
  {2400, SERIAL_8N1, "2400 8N1"}, {2400, SERIAL_7E1, "2400 7E1"}
};

float parseLastNumber(const String& frame) {
  float result = 0.0; bool found = false;
  int n = frame.length(); int i = 0;
  while (i < n) {
    char c = frame[i];
    bool isStart = isdigit(c) || ((c == '-' || c == '+') && i + 1 < n && isdigit(frame[i + 1]));
    if (isStart) {
      int j = i + 1; bool dot = false;
      while (j < n) {
        char d = frame[j];
        if (isdigit(d)) j++;
        else if ((d == '.' || d == ',') && !dot) { dot = true; j++; }
        else break;
      }
      String tok = frame.substring(i, j);
      tok.replace(',', '.');
      result = tok.toFloat(); found = true; i = j;
    } else i++;
  }
  return found ? result : NAN;
}

void beginScaleSerial(int optIdx) {
  ScaleSerial.end(); delay(20);
  ScaleSerial.begin(scaleOptions[optIdx].baud, scaleOptions[optIdx].config, PIN_SCALE_RX, PIN_SCALE_TX);
  ScaleSerial.setTimeout(100); delay(50);
}

bool lerFrameAte(unsigned long timeoutMs) {
  String local = "";
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (ScaleSerial.available()) {
      char c = (char)ScaleSerial.read();
      if (DEBUG_SCALE) Serial.printf("%02X ", (uint8_t)c);
      if (c == '\r' || c == '\n' || c == 0x03) {
        if (local.length() > 0 && !isnan(parseLastNumber(local))) return true;
        local = "";
      } else if (local.length() < 64) local += c;
      else local = "";
    }
  }
  return false;
}
bool listenForFrame(unsigned long timeoutMs) { while (ScaleSerial.available()) ScaleSerial.read(); return lerFrameAte(timeoutMs); }
bool tryDetect(int cmdIdx, unsigned long timeoutMs) {
  while (ScaleSerial.available()) ScaleSerial.read();
  ScaleSerial.print(pollingCommands[cmdIdx]);
  return lerFrameAte(timeoutMs);
}

void scaleDetected(int optIdx, int cmdIdx) {
  Serial.printf("\nBALANCA DETECTADA: %s (comando idx %d)\n", scaleOptions[optIdx].label, cmdIdx);
  lcdMain("BALANCA OK!", scaleOptions[optIdx].label);
  last_baud_idx = optIdx; last_cmd_idx = cmdIdx;
  prefs.begin("balanca-cfg", false);
  prefs.putInt("last_baud", optIdx); prefs.putInt("last_cmd", cmdIdx);
  prefs.end();
  scaleRxBuf = ""; lastValidWeight = NAN; lastWeightMs = 0; lastByteRxMs = millis();
  delay(800);
}

void autoConfigScale() {
  lcdMain("BUSCANDO", "BALANCA...");
  lcdSec("Aguarde...", "Scan Ativo");
  int numOptions = sizeof(scaleOptions) / sizeof(scaleOptions[0]);
  if (last_baud_idx >= 0 && last_baud_idx < numOptions) {
    int cmd = (last_cmd_idx >= 0 && last_cmd_idx < numPollCommands) ? last_cmd_idx : 0;
    lcdSec("Ultima config:", scaleOptions[last_baud_idx].label);
    beginScaleSerial(last_baud_idx);
    if (listenForFrame(1500) || tryDetect(cmd, 1500)) { scaleDetected(last_baud_idx, cmd); return; }
  }
  for (int i = 0; i < numOptions; i++) {
    if (i == last_baud_idx) continue;
    lcdSec("Tentando:", scaleOptions[i].label);
    beginScaleSerial(i);
    if (listenForFrame(800)) { scaleDetected(i, last_cmd_idx >= 0 ? last_cmd_idx : 0); return; }
    for (int j = 0; j < numPollCommands; j++) if (tryDetect(j, 1000)) { scaleDetected(i, j); return; }
  }
  lcdMain("FALHA DETECCAO", "Usando Padrao");
  last_baud_idx = 0; lastValidWeight = NAN;
  beginScaleSerial(0);
  delay(1000);
}

void registrarPeso(float w) {
  lastValidWeight = w; lastWeightMs = millis();
  if (isnan(estabRef) || fabsf(w - estabRef) > 0.005f) { estabRef = w; estabDesdeMs = millis(); }
}

void pumpScaleSerial() {
  while (ScaleSerial.available()) {
    char c = (char)ScaleSerial.read();
    lastByteRxMs = millis();
    if (c == '\r' || c == '\n' || c == 0x03) {
      if (scaleRxBuf.length() > 0) {
        float w = parseLastNumber(scaleRxBuf);
        if (DEBUG_SCALE) Serial.printf("[BALANCA] frame='%s'\n", scaleRxBuf.c_str());
        scaleRxBuf = "";
        if (!isnan(w)) registrarPeso(w);
      }
    } else if (scaleRxBuf.length() < 64) scaleRxBuf += c;
    else scaleRxBuf = "";
  }
  if (scaleRxBuf.length() > 0 && millis() - lastByteRxMs > 150) {
    float w = parseLastNumber(scaleRxBuf);
    scaleRxBuf = "";
    if (!isnan(w)) registrarPeso(w);
  }
  if (millis() - lastByteRxMs > 800 && millis() - lastPollMs > 400) {
    lastPollMs = millis();
    int cmd = (last_cmd_idx >= 0 && last_cmd_idx < numPollCommands) ? last_cmd_idx : 0;
    ScaleSerial.print(pollingCommands[cmd]);
  }
}
float getWeightFromScale() {
  pumpScaleSerial();
  if (!isnan(lastValidWeight) && (millis() - lastWeightMs < 3000)) return lastValidWeight;
  return NAN;
}
bool leituraEstavel() { return !isnan(estabRef) && millis() - estabDesdeMs >= 1000; }

// ============================================================================
// 7. SUPABASE (HTTPS + RPC)
// ============================================================================
// Retorna o código HTTP (200 = processado) ou negativo em falha de rede/JSON.
int callRpc(const char* fn, const String& body, JsonDocument& out, uint32_t timeoutMs = 8000) {
  if (WiFi.status() != WL_CONNECTED) return -1;
  HTTPClient http;
  String url = cfg.url + "/rest/v1/rpc/" + fn;
  bool ok = cfg.url.startsWith("https://") ? http.begin(tls, url) : http.begin(plain, url);
  if (!ok) return -2;
  http.setConnectTimeout(5000);
  http.setTimeout(timeoutMs);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", cfg.apikey);
  if (cfg.apikey.startsWith("eyJ")) http.addHeader("Authorization", "Bearer " + cfg.apikey);  // anon key legada (JWT)
  http.addHeader("x-device-id", deviceId);
  http.addHeader("x-device-key", cfg.devkey);
  if (DEBUG_HTTP) { Serial.printf("\n>> %s %s\n", fn, body.c_str()); }
  int code = http.POST(body);
  if (code > 0) {
    String resp = http.getString();
    if (DEBUG_HTTP) Serial.printf("<< %d %s\n", code, resp.substring(0, 600).c_str());
    out.clear();
    if (deserializeJson(out, resp) && code == 200) code = -3;
  } else if (DEBUG_HTTP) {
    Serial.printf("<< ERRO %d %s\n", code, http.errorToString(code).c_str());
  }
  http.end();
  return code;
}

Evento novoEvento(const char* tipo, JsonDocument& dados) {
  Evento e;
  e.tipo = tipo;
  e.id = uuid4();
  serializeJson(dados, e.dados);       // o MESMO texto é usado online e na fila (idempotência por hash)
  return e;
}
String corpoOnline(const Evento& e) {
  return "{\"p_tipo\":\"" + e.tipo + "\",\"p_event_id\":\"" + e.id + "\",\"p_dados\":" + e.dados + "}";
}
String linhaFila(const Evento& e) {
  return "{\"tipo\":\"" + e.tipo + "\",\"event_id\":\"" + e.id + "\",\"dados\":" + e.dados + "}";
}

// Eventos de navegação (antes de iniciar a pesagem): exigem conexão.
int enviarOnline(const Evento& e, JsonDocument& resp) { return callRpc("terminal_evento", corpoOnline(e), resp); }

// ---------------------------------------------------------------------------
// 7.1 FILA OFFLINE NO microSD  (/fila/0000000001.ev ... em ordem)
// ---------------------------------------------------------------------------
uint32_t filaCabeca = 0, filaCauda = 0;

String caminhoFila(uint32_t n) { char b[24]; snprintf(b, sizeof(b), "/fila/%010lu.ev", (unsigned long)n); return String(b); }
void salvarPonteirosFila() {
  prefs.begin("fila", false);
  prefs.putULong("cab", filaCabeca); prefs.putULong("cau", filaCauda);
  prefs.end();
}
uint32_t filaPendentes() { return filaCauda - filaCabeca; }

bool filaGravar(const Evento& e) {
  if (!sdOk) return false;
  String linha = linhaFila(e);
  File f = SD.open(caminhoFila(filaCauda), FILE_WRITE);
  if (!f) { sdOk = false; return false; }
  size_t n = f.print(linha);
  f.flush(); f.close();
  if (n != linha.length()) { sdOk = false; return false; }
  filaCauda++;
  salvarPonteirosFila();
  return true;
}

void filaDescartarCabeca(bool paraFalhas) {
  String p = caminhoFila(filaCabeca);
  if (paraFalhas) { SD.mkdir("/falhas"); SD.rename(p, "/falhas" + p.substring(5)); }
  else SD.remove(p);
  filaCabeca++;
  falhasCabecaFila = 0;
  salvarPonteirosFila();
}

// Envia até SYNC_LOTE eventos da fila em ORDEM. Retorna true se avançou.
bool filaSincronizar() {
  if (!sdOk || filaPendentes() == 0 || WiFi.status() != WL_CONNECTED) return false;
  String corpo = "{\"p_eventos\":[";
  int n = 0;
  JsonDocument teste;
  while (n < SYNC_LOTE && filaCabeca + n < filaCauda) {
    File f = SD.open(caminhoFila(filaCabeca + n), FILE_READ);
    if (!f) {                                   // arquivo perdido: só pode ser descartado se for a cabeça
      if (n == 0) { filaDescartarCabeca(false); continue; }
      break;
    }
    String linha = f.readString(); f.close();
    if (deserializeJson(teste, linha)) {        // corrompido (queda de energia na escrita)
      if (n == 0) { filaDescartarCabeca(true); continue; }
      break;
    }
    if (n > 0) corpo += ",";
    corpo += linha;
    n++;
  }
  corpo += "]}";
  if (n == 0) return false;

  JsonDocument resp;
  int code = callRpc("terminal_sincronizar", corpo, resp, 20000);
  if (code != 200) return false;
  JsonArray rs = resp["resultados"].as<JsonArray>();
  bool avancou = false;
  for (int i = 0; i < n && i < (int)rs.size(); i++) {
    bool retry = rs[i]["retry"] | true;
    if (!retry) { filaDescartarCabeca(false); avancou = true; }
    else {
      if (++falhasCabecaFila >= MAX_TENTATIVAS_EVENTO) filaDescartarCabeca(true);
      break;                                    // preserva a ordem
    }
  }
  return avancou;
}
void filaDrenar(unsigned long limiteMs) {
  unsigned long t0 = millis();
  while (filaPendentes() > 0 && millis() - t0 < limiteMs && filaSincronizar()) {}
}

// Pesagem/finalização/log: grava no SD antes (write-ahead), depois tenta online.
// Retorna 1 = processado agora (resp válido) | 0 = pendente na fila | -1 = não enviado e não guardado
int enviarComFila(const Evento& e, JsonDocument& resp) {
  bool haviaFila = filaPendentes() > 0;
  bool gravou = filaGravar(e);
  if (haviaFila && gravou) {                    // há eventos anteriores: mantém a ordem pela fila
    filaDrenar(4000);
    return 0;
  }
  int code = enviarOnline(e, resp);
  if (code == 200) {
    if (gravou) filaDescartarCabeca(false);     // a fila estava vazia: este é a cabeça
    return 1;
  }
  return gravou ? 0 : -1;
}

// ---------------------------------------------------------------------------
// 7.2 Sessão persistida (sobrevive a reboot/queda de energia)
// ---------------------------------------------------------------------------
void salvarSessao() {
  JsonDocument d;
  d["a"] = S.ativa; d["id"] = S.id; d["op"] = S.operador; d["pr"] = S.produto; d["em"] = S.embalagem;
  d["n"] = S.nominal; d["mi"] = S.minKg; d["ma"] = S.maxKg;
  d["v"] = S.validas; d["f"] = S.fora; d["r"] = S.rejeitadas; d["s"] = S.seq; d["kg"] = S.kgValido;
  String s; serializeJson(d, s);
  prefs.begin("sessao", false); prefs.putString("s", s); prefs.end();
}
void carregarSessao() {
  prefs.begin("sessao", true); String s = prefs.getString("s", ""); prefs.end();
  JsonDocument d;
  if (s.length() == 0 || deserializeJson(d, s)) { S = Sessao(); return; }
  S.ativa = d["a"] | false; S.id = d["id"] | ""; S.operador = d["op"] | ""; S.produto = d["pr"] | "";
  S.embalagem = d["em"] | ""; S.nominal = d["n"] | 0.0; S.minKg = d["mi"] | 0.0; S.maxKg = d["ma"] | 0.0;
  S.validas = d["v"] | 0; S.fora = d["f"] | 0; S.rejeitadas = d["r"] | 0; S.seq = d["s"] | 0; S.kgValido = d["kg"] | 0.0;
}
void limparSessao() { S = Sessao(); salvarSessao(); }

// Copia a sessão vinda do servidor (resposta de INICIAR, heartbeat ou TERMINAL_COM_SESSAO_EM_ANDAMENTO)
void sessaoDoServidor(JsonVariantConst j) {
  S.ativa = true;
  S.id = j["sessao_id"] | "";
  S.operador = j["operador"]["nome"] | "";
  S.produto = j["produto"]["nome"] | "";
  S.embalagem = j["embalagem"]["nome"] | "";
  S.nominal = j["peso_nominal_kg"] | 0.0;
  S.minKg = j["tolerancia"]["limite_min_kg"] | 0.0;
  S.maxKg = j["tolerancia"]["limite_max_kg"] | 0.0;
  S.validas = j["totais"]["validas"] | 0;
  S.fora = j["totais"]["fora_tolerancia"] | 0;
  S.rejeitadas = j["totais"]["rejeitadas"] | 0;
  S.kgValido = j["totais"]["peso_valido_kg"] | 0.0;
  if (S.seq < (int)(j["totais"]["pesagens"] | 0)) S.seq = j["totais"]["pesagens"] | 0;
  salvarSessao();
}

// ---------------------------------------------------------------------------
// 7.3 Heartbeat
// ---------------------------------------------------------------------------
const char* nomeEstado() {
  switch (estado) {
    case ST_AGUARDANDO_RFID: return "AGUARDANDO_RFID";
    case ST_CONFIRMAR_OPERADOR: return "OPERADOR_IDENTIFICADO";
    case ST_SEL_PRODUTO: return "SELECIONANDO_PRODUTO";
    case ST_SEL_PESO: return "SELECIONANDO_PESO";
    case ST_SEL_EMBALAGEM: return "SELECIONANDO_EMBALAGEM";
    case ST_CONFIRMAR_INICIO: return "PRONTO_PARA_INICIAR";
    default: return "PESAGEM_EM_ANDAMENTO";
  }
}
bool heartbeat(JsonDocument& resp) {
  JsonDocument d;
  d["firmware_versao"] = FW_VERSION;
  d["estado"] = nomeEstado();
  d["eventos_pendentes"] = filaPendentes();
  d["ip"] = WiFi.localIP().toString();
  d["rssi"] = WiFi.RSSI();
  d["sd"] = sdOk;
  String dados; serializeJson(d, dados);          // serializeJson LIMPA a String de destino
  String body = "{\"p_dados\":" + dados + "}";
  ultimoHeartbeat = millis();
  return callRpc("terminal_heartbeat", body, resp) == 200;
}

// Mensagens de LCD para os códigos devolvidos pelo servidor
void textoCodigo(const String& codigo, String& l1, String& l2) {
  if (codigo == "RFID_INVALIDO")                         { l1 = "CARTAO NAO";      l2 = "CADASTRADO"; }
  else if (codigo == "RFID_INATIVO")                     { l1 = "CARTAO";          l2 = "BLOQUEADO"; }
  else if (codigo == "RFID_SEM_OPERADOR")                { l1 = "CARTAO SEM";      l2 = "OPERADOR"; }
  else if (codigo == "OPERADOR_INATIVO")                 { l1 = "OPERADOR";        l2 = "INATIVO"; }
  else if (codigo == "OPERADOR_COM_SESSAO_EM_ANDAMENTO") { l1 = "OPERADOR PESANDO"; l2 = "EM OUTRA BALANCA"; }
  else if (codigo == "CANCELAMENTO_BLOQUEADO")           { l1 = "CANCELAR BLOQ.";  l2 = "USE FINALIZAR"; }
  else if (codigo == "SEM_REGRA_TOLERANCIA")             { l1 = "SEM TOLERANCIA";  l2 = "CADASTRADA"; }
  else if (codigo == "PRODUTO_INDISPONIVEL" || codigo == "PESO_INDISPONIVEL" ||
           codigo == "EMBALAGEM_INDISPONIVEL" || codigo == "ESPECIFICACAO_INDISPONIVEL") { l1 = "ITEM INDISPON."; l2 = "CADASTRO MUDOU"; }
  else if (codigo == "ESTADO_INVALIDO" || codigo == "SESSAO_NAO_ENCONTRADA") { l1 = "SESSAO INVALIDA"; l2 = "RECOMECE"; }
  else                                                   { l1 = "ERRO SERVIDOR";   l2 = codigo; }
}

void erroRede(int code, Estado depois) {
  if (code == 401) mensagem("TERMINAL NAO", "AUTORIZADO 401", 4000, depois);
  else if (code == 403) mensagem("TERMINAL", "INATIVO 403", 4000, depois);
  else if (code < 0) mensagem("SEM CONEXAO", "VERIFIQUE WIFI", 3000, depois);
  else mensagem("ERRO HTTP", String(code), 3000, depois);
}

// ============================================================================
// 8. MÁQUINA DE ESTADOS
// ============================================================================
JsonArray produtos() { return catalogo["produtos"].as<JsonArray>(); }
JsonArray pesos()    { return produtos()[idxProd]["pesos"].as<JsonArray>(); }
JsonArray embalagens() { return pesos()[idxPeso]["embalagens"].as<JsonArray>(); }

void navegar(int& idx, int total) {
  if (total <= 0) return;
  if (bCima.clicou)  { idx = (idx - 1 + total) % total; redesenhar = true; }
  if (bBaixo.clicou) { idx = (idx + 1) % total; redesenhar = true; }
}

// Envia evento de navegação; em caso de falha mostra erro e volta para AGUARDANDO_RFID
bool eventoNavegacao(const char* tipo, JsonDocument& dados, JsonDocument& resp, Estado seFalhar = ST_AGUARDANDO_RFID) {
  lcdSec("Enviando...", "");
  Evento e = novoEvento(tipo, dados);
  int code = enviarOnline(e, resp);
  if (code != 200) { erroRede(code, seFalhar); return false; }
  if (!(resp["ok"] | false)) {
    String l1, l2; textoCodigo(resp["codigo"] | "?", l1, l2);
    mensagem(l1, l2, 3500, seFalhar);
    return false;
  }
  return true;
}

void cancelarSessaoPreInicio(const char* motivo) {
  if (sessaoIdPreInicio.length() > 0 && WiFi.status() == WL_CONNECTED) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["motivo"] = motivo; d["ocorrido_em"] = isoAgora();
    Evento e = novoEvento("CANCELAR_SESSAO", d);
    enviarOnline(e, r);           // se falhar, o servidor cancela ao identificar o próximo cartão
  }
  sessaoIdPreInicio = "";
  mensagem("OPERACAO", "CANCELADA", 1500, ST_AGUARDANDO_RFID, false);
}

// ---- ESTADO 1: AGUARDANDO RFID ----------------------------------------------
void st_aguardandoRfid() {
  if (redesenhar) {
    redesenhar = false;
    lcdMain("APROXIME CARTAO", "P/ INICIAR...");
    String l2 = WiFi.status() == WL_CONNECTED ? "ONLINE" : "OFFLINE";
    if (filaPendentes() > 0) l2 += " SYNC:" + String(filaPendentes());
    if (!sdOk) l2 += " SEM SD";
    lcdSec("ID " + deviceId, l2);
    setLeds(false, false);
  }
  if (WiFi.status() == WL_CONNECTED) {
    if (filaPendentes() > 0 && millis() - ultimoSync > SYNC_RETRY_MS) { ultimoSync = millis(); filaSincronizar(); redesenhar = true; }
    if (millis() - ultimoHeartbeat > HEARTBEAT_MS) { JsonDocument r; heartbeat(r); redesenhar = true; }
  }

  String uid = readRFID();
  if (uid == "") return;
  digitalWrite(PIN_LED_VERDE, HIGH); delay(80); digitalWrite(PIN_LED_VERDE, LOW);
  lcdMain("CARTAO:", uid);
  if (WiFi.status() != WL_CONNECTED) {           // REGRA 1: cartão só é validado pelo servidor
    mensagem("SEM CONEXAO", "NAO PODE INICIAR", 3000, ST_AGUARDANDO_RFID);
    return;
  }
  filaDrenar(5000);                               // pendências antigas primeiro (ordem)

  JsonDocument d, r;
  d["uid"] = uid; d["ocorrido_em"] = isoAgora();
  lcdSec("Verificando...", "Aguarde");
  Evento e = novoEvento("IDENTIFICAR_CARTAO", d);
  int code = enviarOnline(e, r);
  if (code != 200) { erroRede(code, ST_AGUARDANDO_RFID); return; }

  String codigo = r["codigo"] | "";
  if (codigo == "TERMINAL_COM_SESSAO_EM_ANDAMENTO") {   // sessão aberta neste terminal: retoma
    sessaoDoServidor(r["sessao"]);
    mensagem("SESSAO ABERTA", "RETOMANDO...", 2000, ST_PESAGEM, false);
    autoConfigScale();
    return;
  }
  if (!(r["ok"] | false)) {
    String l1, l2; textoCodigo(codigo, l1, l2);
    mensagem(l1, l2, 3500, ST_AGUARDANDO_RFID);
    return;
  }
  sessaoIdPreInicio = r["sessao_id"] | "";
  operadorNome = r["mensagem"] | "Operador";
  catalogo.clear();
  catalogo["produtos"] = r["catalogo"];
  idxProd = idxPeso = idxEmb = 0;
  irPara(ST_CONFIRMAR_OPERADOR);
}

// ---- CONFIRMAÇÃO DO OPERADOR -----------------------------------------------------
void st_confirmarOperador() {
  if (redesenhar) {
    redesenhar = false;
    lcdMain("OPERADOR:", operadorNome);
    lcdSec("CONFIRMAR = SIM", "CANCELAR = NAO");
  }
  if (bConf.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["confirmado"] = true; d["ocorrido_em"] = isoAgora();
    if (!eventoNavegacao("CONFIRMAR_OPERADOR", d, r)) return;
    if (produtos().size() == 0) { cancelarSessaoPreInicio("SEM_PRODUTOS"); mensagem("SEM PRODUTOS", "NO CADASTRO", 3000, ST_AGUARDANDO_RFID); return; }
    irPara(ST_SEL_PRODUTO);
  } else if (bCanc.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["confirmado"] = false; d["ocorrido_em"] = isoAgora();
    Evento e = novoEvento("CONFIRMAR_OPERADOR", d);
    enviarOnline(e, r);
    sessaoIdPreInicio = "";
    mensagem("IDENTIDADE", "NAO CONFIRMADA", 2000, ST_AGUARDANDO_RFID);
  }
}

// ---- SELEÇÃO DO PRODUTO ----------------------------------------------------------
void st_selProduto() {
  JsonArray ps = produtos();
  navegar(idxProd, ps.size());
  if (redesenhar) {
    redesenhar = false;
    lcdMain("PRODUTO:", ps[idxProd]["nome"] | "?");
    lcdSec(String(idxProd + 1) + "/" + String(ps.size()) + " SETAS NAVEG.", "CONF=OK CANC=SAI");
  }
  if (bConf.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["produto_id"] = ps[idxProd]["id"]; d["ocorrido_em"] = isoAgora();
    if (!eventoNavegacao("SELECIONAR_PRODUTO", d, r)) return;
    idxPeso = 0;
    irPara(ST_SEL_PESO);
  } else if (bCanc.clicou) {
    cancelarSessaoPreInicio("CANCELADO_NA_SELECAO_PRODUTO");
  }
}

// ---- SELEÇÃO DO PESO NOMINAL ---------------------------------------------------
void st_selPeso() {
  JsonArray ws = pesos();
  navegar(idxPeso, ws.size());
  if (redesenhar) {
    redesenhar = false;
    float w = ws[idxPeso]["peso_kg"] | 0.0;
    lcdMain("PESO NOMINAL:", String(w, 3) + " kg");
    lcdSec(String(idxPeso + 1) + "/" + String(ws.size()) + " SETAS NAVEG.", "CONF=OK CANC=VOLT");
  }
  if (bConf.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["peso_nominal_kg"] = ws[idxPeso]["peso_kg"]; d["ocorrido_em"] = isoAgora();
    if (!eventoNavegacao("SELECIONAR_PESO", d, r)) return;
    idxEmb = 0;
    irPara(ST_SEL_EMBALAGEM);
  } else if (bCanc.clicou) {
    irPara(ST_SEL_PRODUTO);                     // volta; a nova seleção reinicia o restante no servidor
  }
}

// ---- SELEÇÃO DA EMBALAGEM -------------------------------------------------------------
void st_selEmbalagem() {
  JsonArray es = embalagens();
  navegar(idxEmb, es.size());
  if (redesenhar) {
    redesenhar = false;
    lcdMain("EMBALAGEM:", es[idxEmb]["nome"] | "?");
    lcdSec(String(idxEmb + 1) + "/" + String(es.size()) + " SETAS NAVEG.", "CONF=OK CANC=VOLT");
  }
  if (bConf.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["tipo_embalagem_id"] = es[idxEmb]["id"]; d["ocorrido_em"] = isoAgora();
    if (!eventoNavegacao("SELECIONAR_EMBALAGEM", d, r)) return;
    previaMin = r["previa_tolerancia"]["limite_min_kg"] | 0.0;
    previaMax = r["previa_tolerancia"]["limite_max_kg"] | 0.0;
    irPara(ST_CONFIRMAR_INICIO);
  } else if (bCanc.clicou) {
    irPara(ST_SEL_PESO);
  }
}

// ---- INICIAR PESAGEM? ---------------------------------------------------------------------
void st_confirmarInicio() {
  if (redesenhar) {
    redesenhar = false;
    lcdMain("INICIAR PESAGEM?", String(pesos()[idxPeso]["peso_kg"] | 0.0, 1) + "kg " + String(embalagens()[idxEmb]["nome"] | ""));
    lcdSec("Tol " + String(previaMin, 2) + "-" + String(previaMax, 2), "CONF=SIM CANC=NAO");
  }
  if (bConf.clicou) {
    JsonDocument d, r;
    d["sessao_id"] = sessaoIdPreInicio; d["ocorrido_em"] = isoAgora();
    if (!eventoNavegacao("INICIAR_PESAGEM", d, r)) return;
    S = Sessao();
    sessaoDoServidor(r["sessao"]);              // tolerância CONGELADA vinda do servidor
    sessaoIdPreInicio = "";
    autoConfigScale();
    //tareScale(); // tara desativada (mesmo comportamento da v3)
    irPara(ST_PESAGEM);
  } else if (bCanc.clicou) {
    cancelarSessaoPreInicio("CANCELADO_NA_CONFIRMACAO_INICIAL");
  }
}

// ---- PESAGEM EM ANDAMENTO ---------------------------------------------------------------
void desenharPesagem(float w) {
  bool temPeso = !isnan(w);
  String ind = !temPeso ? "--" : (w >= S.minKg && w <= S.maxKg ? "OK" : "FORA");
  lcdMain("PESO:" + (temPeso ? String(w, 3) : String("  ---  ")) + "kg", String(S.minKg, 2) + "-" + String(S.maxKg, 2) + " " + ind);
  String l1 = "OK:" + String(S.validas) + " F:" + String(S.fora);
  if (filaPendentes() > 0) l1 += " S" + String(filaPendentes());
  lcdSec(l1, "CONF=GRAVA 3=FIM");
  setLeds(temPeso && ind == "OK", temPeso && ind == "FORA");
}

void st_pesagem() {
  float w = getWeightFromScale();
  static float mostrado = -99999;
  static uint32_t pendMostrado = 0;
  if (redesenhar || (isnan(w) != isnan(mostrado)) || (!isnan(w) && fabsf(w - mostrado) > 0.0005f) || pendMostrado != filaPendentes()) {
    redesenhar = false; mostrado = w; pendMostrado = filaPendentes();
    desenharPesagem(w);
  }
  if (filaPendentes() > 0 && WiFi.status() == WL_CONNECTED && millis() - ultimoSync > SYNC_RETRY_MS) {
    ultimoSync = millis(); filaSincronizar();
  }
  if (WiFi.status() == WL_CONNECTED && millis() - ultimoHeartbeat > HEARTBEAT_MS) {
    JsonDocument hb;
    if (heartbeat(hb) && hb["sessao_aberta"].isNull() && filaPendentes() == 0) {
      // sessão encerrada no servidor (ex.: supervisor usou admin_sessao_encerrar)
      limparSessao();
      mensagem("SESSAO ENCERRADA", "PELO SISTEMA", 4000, ST_AGUARDANDO_RFID);
      return;
    }
  }

  if (bCanc.clicou) {                            // REGRA 10: cancelar bloqueado após iniciar
    lcdMain("CANCELAR BLOQ.", "USE FINALIZAR");
    setLeds(false, true);
    if (WiFi.status() == WL_CONNECTED && filaPendentes() == 0) {   // registra a tentativa (auditoria)
      JsonDocument d, r; d["sessao_id"] = S.id; d["ocorrido_em"] = isoAgora();
      Evento e = novoEvento("CANCELAR_SESSAO", d); enviarOnline(e, r);
    }
    delay(1500); redesenhar = true;
    return;
  }

  if (bConf.clicou) {
    if (isnan(w)) { mensagem("SEM LEITURA", "DA BALANCA", 2000, ST_PESAGEM); return; }
    Evento e;
    if (temEventoRam) e = eventoRam;            // reenvia o MESMO evento (mesmo event_id)
    else {
      JsonDocument d;
      d["sessao_id"] = S.id;
      d["peso_lido"] = serialized(String(w, 3));
      d["unidade"] = "kg";
      d["lido_em"] = isoDeMillis(lastWeightMs);
      d["confirmado_em"] = isoAgora();
      d["sequencia_terminal"] = S.seq + 1;
      d["leitura_estavel"] = leituraEstavel();
      e = novoEvento("CONFIRMAR_PESAGEM", d);
    }
    lcdSec("Gravando...", "");
    JsonDocument r;
    int res = enviarComFila(e, r);
    if (res < 0) {                              // sem SD e sem rede: não perde, guarda em RAM e pede repetição
      eventoRam = e; temEventoRam = true;
      mensagem("FALHA ENVIO", "CONF=TENTAR NOV", 3000, ST_PESAGEM);
      return;
    }
    temEventoRam = false;
    S.seq++;
    if (res == 1) {                             // resultado oficial do servidor
      ultimoCodigo = r["codigo"] | "";
      ultimoPeso = r["pesagem"]["peso_lido_kg"] | w;
      ultimoPendente = false;
      if (r["totais"].is<JsonObject>()) {
        S.validas = r["totais"]["validas"] | S.validas;
        S.fora = r["totais"]["fora_tolerancia"] | S.fora;
        S.rejeitadas = r["totais"]["rejeitadas"] | S.rejeitadas;
        S.kgValido = r["totais"]["peso_valido_kg"] | S.kgValido;
      }
      if (ultimoCodigo == "SESSAO_NAO_EM_PESAGEM") {    // sessão encerrada no servidor (ex.: supervisor)
        limparSessao();
        mensagem("SESSAO ENCERRADA", "PELO SISTEMA", 4000, ST_AGUARDANDO_RFID);
        return;
      }
    } else {                                    // prévia local; o servidor decide na sincronização
      ultimoPeso = w;
      ultimoPendente = true;
      bool dentro = (w >= S.minKg && w <= S.maxKg);
      ultimoCodigo = dentro ? "PESAGEM_CONFIRMADA" : "FORA_TOLERANCIA";
      if (dentro) { S.validas++; S.kgValido += w; } else S.fora++;
    }
    salvarSessao();
    irPara(ST_RESULTADO);
    return;
  }

  if (bFim.clicou) {
    lcdMain("FINALIZANDO...", "Aguarde");
    JsonDocument d, r;
    d["sessao_id"] = S.id; d["ocorrido_em"] = isoAgora();
    Evento e = novoEvento("FINALIZAR_SESSAO", d);
    int res = enviarComFila(e, r);
    if (res < 0) { mensagem("FALHA ENVIO", "TENTE FINALIZAR", 3000, ST_PESAGEM); return; }
    String l1 = "OK:" + String(S.validas) + " FORA:" + String(S.fora);
    String l2 = String(S.kgValido, 1) + "kg";
    if (res == 1 && r["sessao"]["totais"].is<JsonObject>()) {
      JsonObject t = r["sessao"]["totais"];
      l1 = "OK:" + String((int)(t["validas"] | 0)) + " FORA:" + String((int)(t["fora_tolerancia"] | 0));
      l2 = String((float)(t["peso_valido_kg"] | 0.0), 1) + "kg " + String((int)((t["duracao_seg"] | 0.0) / 60)) + "min";
    } else if (res == 0) l2 += " (SYNC)";
    limparSessao();
    lcdSec("SESSAO FINALIZ.", "");
    mensagem(l1, l2, 5000, ST_AGUARDANDO_RFID, false);
  }
}

// ---- RESULTADO DA PESAGEM ---------------------------------------------------------------
unsigned long resultadoDesde = 0;
void st_resultado() {
  if (redesenhar) {
    redesenhar = false;
    resultadoDesde = millis();
    String sufixo = ultimoPendente ? " *" : "";
    if (ultimoCodigo == "PESAGEM_CONFIRMADA") {
      lcdMain("PESAGEM OK" + sufixo, String(ultimoPeso, 3) + " kg");
      setLeds(true, false);
    } else if (ultimoCodigo == "FORA_TOLERANCIA") {
      lcdMain("FORA TOLERANCIA" + sufixo, String(ultimoPeso, 3) + " kg NAO");
      setLeds(false, true);
    } else if (ultimoCodigo == "ESTOQUE_INSUFICIENTE") {
      lcdMain("SEM ESTOQUE", "ORIGEM: REJEIT.");
      setLeds(false, true);
    } else {
      String l1, l2; textoCodigo(ultimoCodigo, l1, l2);
      lcdMain(l1, l2); setLeds(false, true);
    }
    lcdSec("OK:" + String(S.validas) + " F:" + String(S.fora), ultimoPendente ? "* pendente sync" : "registrado");
  }
  if (millis() - resultadoDesde > 1800) irPara(ST_REMOVER_PESO);
}

unsigned long removerDesde = 0;
void st_removerPeso() {
  if (redesenhar) { redesenhar = false; removerDesde = millis(); lcdSec("REMOVA O PESO", "DA BALANCA..."); }
  float w = getWeightFromScale();
  if ((!isnan(w) && w <= 0.05) || millis() - removerDesde > 8000) irPara(ST_PESAGEM);
}

void st_mensagem() {
  if (millis() >= mensagemAte) { setLeds(false, false); irPara(estadoAposMensagem); }
}

// ============================================================================
// 9. SETUP / WIFI / LOOP
// ============================================================================
bool salvarConfigPortal = false;

void configurarWiFi(bool forcarPortal) {
  WiFiManager wm;
  wm.setSaveConfigCallback([]() { salvarConfigPortal = true; });
  wm.setConnectTimeout(30);
  wm.setConfigPortalTimeout(300);
  WiFiManagerParameter pUrl("sb_url", "Supabase URL (https://xxx.supabase.co ou http://IP-do-PC:54321)", cfg.url.c_str(), 120);
  WiFiManagerParameter pKey("sb_key", "Supabase API key (publishable/anon)", cfg.apikey.c_str(), 300);
  WiFiManagerParameter pDev("dev_key", "Chave do terminal", cfg.devkey.c_str(), 80);
  wm.addParameter(&pUrl); wm.addParameter(&pKey); wm.addParameter(&pDev);

  lcdMain("CONF. WIFI", "Rede: " + String(AP_NAME));
  lcdSec("Senha: " + String(AP_PASSWORD), "IP: 192.168.4.1");
  bool ok = forcarPortal ? wm.startConfigPortal(AP_NAME, AP_PASSWORD) : wm.autoConnect(AP_NAME, AP_PASSWORD);

  if (salvarConfigPortal) {
    cfg.url = String(pUrl.getValue()); cfg.url.trim();
    while (cfg.url.endsWith("/")) cfg.url.remove(cfg.url.length() - 1);
    cfg.apikey = String(pKey.getValue()); cfg.apikey.trim();
    cfg.devkey = String(pDev.getValue()); cfg.devkey.trim();
    prefs.begin("supabase", false);
    prefs.putString("url", cfg.url); prefs.putString("key", cfg.apikey); prefs.putString("dev", cfg.devkey);
    prefs.end();
  }
  if (!ok) {
    // Sem Wi-Fi o terminal continua: pesagens de uma sessão já aberta vão para o microSD.
    lcdMain("WIFI INDISPONIV.", "MODO OFFLINE");
    delay(1500);
    WiFi.mode(WIFI_STA);
    WiFi.begin();                 // continua tentando reconectar em segundo plano
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println("\n--- TERMINAL DE PESAGEM v" FW_VERSION " ---");

  pinMode(PIN_BTN_CONFIRMAR, INPUT_PULLUP);
  pinMode(PIN_BTN_CANCELAR, INPUT_PULLUP);
  pinMode(PIN_BTN_SETA_CIMA, INPUT_PULLUP);
  pinMode(PIN_BTN_SETA_BAIXO, INPUT_PULLUP);
  pinMode(PIN_BTN_FINALIZAR, INPUT_PULLUP);
  pinMode(PIN_LED_VERMELHO, OUTPUT);
  pinMode(PIN_LED_VERDE, OUTPUT);
  pinMode(PIN_SD_CS, OUTPUT); digitalWrite(PIN_SD_CS, HIGH);
  pinMode(PIN_RFID_SS, OUTPUT); digitalWrite(PIN_RFID_SS, HIGH);

  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setClock(100000);
  lcd_main.begin(16, 2); lcd_sec.begin(16, 2);
  lcd_main.clear(); lcd_sec.clear();
  lcdMain("INICIANDO...", "v" FW_VERSION);

  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI);
  rfid.PCD_Init();
  sdOk = SD.begin(PIN_SD_CS, SPI, 4000000);
  if (sdOk) SD.mkdir("/fila");
  Serial.printf("microSD: %s\n", sdOk ? "OK" : "AUSENTE (fila offline desativada)");

  deviceId = getChipID();
  prefs.begin("balanca-cfg", true);
  last_baud_idx = prefs.getInt("last_baud", -1);
  last_cmd_idx = prefs.getInt("last_cmd", -1);
  prefs.end();
  prefs.begin("supabase", true);
  cfg.url = prefs.getString("url", ""); cfg.apikey = prefs.getString("key", ""); cfg.devkey = prefs.getString("dev", "");
  prefs.end();
  prefs.begin("fila", true);
  filaCabeca = prefs.getULong("cab", 0); filaCauda = prefs.getULong("cau", 0);
  prefs.end();
  if (filaCauda < filaCabeca) { filaCabeca = filaCauda = 0; salvarPonteirosFila(); }
  carregarSessao();

  Serial.printf("DEVICE ID: %s  | fila pendente: %lu\n", deviceId.c_str(), (unsigned long)filaPendentes());
  lcdMain("ID PLACA:", deviceId);
  lcdSec(sdOk ? "SD OK" : "SEM SD", "FILA: " + String(filaPendentes()));
  delay(2500);

  bool forcarPortal = digitalRead(PIN_BTN_CANCELAR) == LOW || cfg.url.length() == 0 || cfg.devkey.length() == 0;
  configurarWiFi(forcarPortal);

  tls.setInsecure();   // TODO produção: tls.setCACert(<CA raiz do *.supabase.co>) para validar o certificado
  configTime(0, 0, NTP_1, NTP_2);     // eventos em UTC

  // Recuperação após reboot: drena a fila e pergunta ao servidor se há sessão aberta
  if (WiFi.status() == WL_CONNECTED) {
    lcdMain("SINCRONIZANDO", "Aguarde...");
    unsigned long t0 = millis();
    while (!horaValida() && millis() - t0 < 5000) delay(100);
    filaDrenar(20000);
    JsonDocument r;
    if (heartbeat(r)) {
      JsonVariant sa = r["sessao_aberta"];
      if (!sa.isNull() && String(sa["status"] | "") == "PESAGEM_EM_ANDAMENTO") {
        sessaoDoServidor(sa);
        autoConfigScale();
        irPara(ST_PESAGEM);
        return;
      }
      if (filaPendentes() == 0) limparSessao();   // servidor não tem sessão em andamento
    }
  }
  if (S.ativa) {                                  // offline com sessão em andamento: continua pesando
    autoConfigScale();
    irPara(ST_PESAGEM);
    return;
  }
  irPara(ST_AGUARDANDO_RFID);
}

void loop() {
  lerBotoes();
  switch (estado) {
    case ST_AGUARDANDO_RFID:    st_aguardandoRfid(); break;
    case ST_CONFIRMAR_OPERADOR: st_confirmarOperador(); break;
    case ST_SEL_PRODUTO:        st_selProduto(); break;
    case ST_SEL_PESO:           st_selPeso(); break;
    case ST_SEL_EMBALAGEM:      st_selEmbalagem(); break;
    case ST_CONFIRMAR_INICIO:   st_confirmarInicio(); break;
    case ST_PESAGEM:            st_pesagem(); break;
    case ST_RESULTADO:          st_resultado(); break;
    case ST_REMOVER_PESO:       st_removerPeso(); break;
    case ST_MENSAGEM:           st_mensagem(); break;
  }
}
