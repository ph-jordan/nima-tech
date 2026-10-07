// ============================================================================
//  BALANCA INDUSTRIAL - ESP32  |  Firmware v3
// ----------------------------------------------------------------------------
//  CORREÇÕES EM RELAÇÃO À v2 (problema: peso congelava na tela com a balança
//  real; só "atualizava" ao desconectar o cabo DB9):
//
//  1. Comandos de interrogação agora COM terminador ("P\r\n", ENQ, etc.).
//     Balanças industriais normalmente só respondem após CR/LF; o "P" puro
//     da v2 ficava aguardando no buffer da balança e o scan sempre falhava.
//  2. Removida a "rajada de P": millis() % 1000 < 50 enviava centenas de
//     comandos por segundo, inundando balança e buffer RX do ESP32.
//     Agora: interrogação no máximo 1x a cada 400 ms e SOMENTE se a balança
//     estiver em silêncio (modo comando). Balança em modo contínuo não
//     recebe nenhum comando.
//  3. Leitura 100% não-bloqueante: bytes são acumulados e o frame é fechado
//     por CR, LF ou ETX (0x03) — ou por pausa de 150 ms (protocolos sem
//     terminador). Nada de readStringUntil com timeout de 1000 ms + delay.
//  4. Parser robusto: extrai o ÚLTIMO número do frame (suporta sinal e
//     vírgula/ponto decimal) em vez de colar dígitos de vários frames.
//  5. Scanner: detecção exige um FRAME COMPLETO com número (não "qualquer
//     dígito", que gerava falso positivo com ruído e gravava config errada
//     na flash). Testa escuta passiva (modo contínuo) antes de interrogar.
//     Grava também o comando que funcionou (last_cmd).
//  6. LCD do loop de pesagem só redesenha quando o valor muda (sem clear()
//     a cada iteração, que causava flicker e consumia o loop).
//  7. MQTT: setSocketTimeout(5) para o reconnect TLS não travar o loop.
//  8. DEBUG_SCALE: imprime em HEX no Monitor Serial (115200) todos os bytes
//     recebidos durante o scan — use em campo para identificar o protocolo
//     real da balança do cliente.
// ============================================================================

// tareScaleSerial comentada para testar se a tara pode 
// estar interferindo no valor da pesagem

#include <Wire.h>
#include <hd44780.h>
#include <hd44780ioClass/hd44780_I2Cexp.h>
#include <SPI.h>
#include <MFRC522.h>
#include <HardwareSerial.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>
#include "time.h"

#define DEBUG_SCALE true   // false em produção; true para diagnóstico em campo

// 1. HARDWARE
#define PIN_I2C_SDA 21
#define PIN_I2C_SCL 22
#define LCD_ADDR_MAIN 0x27
#define LCD_ADDR_SEC 0x26
#define PIN_RFID_SS 5
#define PIN_RFID_SCK 18
#define PIN_RFID_MISO 19
#define PIN_RFID_MOSI 23
#define PIN_RFID_RST 4
#define PIN_SCALE_RX 17
#define PIN_SCALE_TX 16
#define PIN_BTN_CONFIRMAR 25
#define PIN_BTN_CANCELAR 26
#define PIN_BTN_FINALIZAR 27
#define PIN_BTN_SETA_CIMA 14
#define PIN_BTN_SETA_BAIXO 32
#define PIN_LED_VERDE 12
#define PIN_LED_VERMELHO 13

// 2. OBJETOS
hd44780_I2Cexp lcd_main(LCD_ADDR_MAIN);
hd44780_I2Cexp lcd_sec(LCD_ADDR_SEC);
MFRC522 rfid(PIN_RFID_SS, PIN_RFID_RST);
HardwareSerial ScaleSerial(2);
Preferences preferences;
WiFiClientSecure espClient;
PubSubClient mqttClient(espClient);
HTTPClient http;

// 3. VARIÁVEIS GLOBAIS
const char* URL_BASE = "http://212.85.19.168:3000/api/v1/placa/pesagem";
const char* AP_PASSWORD_PROTECTION = "ALTERE_ANTES_DE_USAR";
char mqtt_broker[100];
char mqtt_port[6];
char mqtt_user[40];
char mqtt_pass[40];
const char* DEFAULT_BROKER = "6df66d562a2e4bbdb0555f70df83a04d.s1.eu.hivemq.cloud";
const char* DEFAULT_PORT = "8883";
const char* DEFAULT_USER = "Samuel";
const char* DEFAULT_PASS = "Telecom25";
String MQTT_CLIENT_ID;
String MQTT_TOPIC_STATUS;
String payloadOnline;
String payloadOffline;
const char* NTP_SERVER = "pool.ntp.org";
const long GMT_OFFSET_SEC = -3 * 3600;

enum SistemaState {
    STATE_BOOT, STATE_WIFI_CONFIG, STATE_WAIT_FOR_CARD,
    STATE_CARD_AUTH, STATE_SHOW_CARD_ERROR, STATE_CONFIRM_USER,
    STATE_SELECT_PACKAGE, STATE_SELECT_WEIGHT, STATE_CONFIRM_WEIGH_START,
    STATE_WEIGHING_LOOP, STATE_WEIGHING_SUCCESS, STATE_WEIGHING_ERROR,
    STATE_SENDING_REPORT, STATE_REPORT_ERROR
};

SistemaState currentState = STATE_BOOT;
String board_position = "";
String last_card_id = "";
String employee_name = "";
JsonDocument employee_data;
String globalCookie = "";
int menu_index_pkg = 0;
int menu_index_wgt = 0;
int last_baud_idx = -1;  // índice da última baud rate funcional (Preferences)
int last_cmd_idx  = -1;  // índice do último comando de interrogação funcional

struct SelectedPackage {
    String name;
    float weight;
    float tolerance;
} selected_package;

float total_weight_session = 0.0;
int package_count_session = 0;
unsigned long session_start_time_epoch = 0;
unsigned long session_end_time_epoch = 0;
bool shouldSaveConfig = false;
float display_weight = 0.0;   // peso exibido no LCD (atualizado pelo loop)

// --- Estado da camada serial da balança ---
String scaleRxBuf = "";
unsigned long lastByteRxMs = 0;
unsigned long lastPollMs = 0;
float lastValidWeight = NAN;
unsigned long lastWeightMs = 0;

struct SerialOption {
    long baud;
    uint32_t config;
    const char* label;
};

// Comandos de interrogação COM terminador (os mais comuns primeiro).
// A v2 enviava "P"/"W" puros: a maioria das balanças só responde após CR/LF.
const char* pollingCommands[] = {"P\r\n", "\x05", "P\r", "W\r\n", "READ\r\n", "\r\n", "P", "W"};
const int numPollCommands = 8;

SerialOption scaleOptions[] = {
    {9600, SERIAL_8N1, "9600 8N1"},
    {9600, SERIAL_7E1, "9600 7E1"},
    {4800, SERIAL_8N1, "4800 8N1"},
    {4800, SERIAL_7E1, "4800 7E1"},
    {2400, SERIAL_8N1, "2400 8N1"},
    {2400, SERIAL_7E1, "2400 7E1"}
};

// 4. FUNÇÕES AUXILIARES
void lcdMainPrint(String l1, String l2) {
    lcd_main.clear();
    lcd_main.setCursor(0, 0); lcd_main.print(l1.substring(0, 16));
    lcd_main.setCursor(0, 1); lcd_main.print(l2.substring(0, 16));
}

void lcdSecPrint(String l1, String l2) {
    lcd_sec.clear();
    lcd_sec.setCursor(0, 0); lcd_sec.print(l1.substring(0, 16));
    lcd_sec.setCursor(0, 1); lcd_sec.print(l2.substring(0, 16));
}

void setLeds(bool verde, bool vermelho) {
    digitalWrite(PIN_LED_VERDE, verde ? HIGH : LOW);
    digitalWrite(PIN_LED_VERMELHO, vermelho ? HIGH : LOW);
}

String readRFID() {
    if (rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
        unsigned long long decNormal = 0;
        for (int i = 0; i < rfid.uid.size; i++) {
            decNormal = (decNormal << 8) | rfid.uid.uidByte[i];
        }
        rfid.PICC_HaltA();
        rfid.PCD_StopCrypto1();
        char buffer[25];
        sprintf(buffer, "%llu", decNormal);
        return String(buffer);
    }
    return "";
}

unsigned long getTimestampEpoch() {
    time_t now;
    time(&now);
    return (unsigned long)now;
}

unsigned long lastDebounceTime = 0;
const unsigned long debounceDelay = 250;

bool readButton(int pin) {
    if (digitalRead(pin) == LOW) {
        if ((millis() - lastDebounceTime) > debounceDelay) {
            lastDebounceTime = millis();
            return true;
        }
    }
    return false;
}

String getChipID() {
    uint64_t chipid = ESP.getEfuseMac();
    char chipIdStr[13];
    snprintf(chipIdStr, 13, "%04X%08X", (uint16_t)(chipid >> 32), (uint32_t)chipid);
    return String(chipIdStr);
}

// ============================================================================
//  CAMADA SERIAL DA BALANÇA (reescrita na v3)
// ============================================================================

// Extrai o ÚLTIMO número do frame (aceita sinal +/- e . ou , decimal).
// Ex.: "ST,GS,+  12.340kg" -> 12.34 | "US,  -0,125" -> -0.125
float parseLastNumber(const String &frame) {
    float result = 0.0;
    bool found = false;
    int n = frame.length();
    int i = 0;
    while (i < n) {
        char c = frame[i];
        bool isStart = isdigit(c) ||
                       ((c == '-' || c == '+') && i + 1 < n && isdigit(frame[i + 1]));
        if (isStart) {
            int j = i + 1;
            bool dot = false;
            while (j < n) {
                char d = frame[j];
                if (isdigit(d)) j++;
                else if ((d == '.' || d == ',') && !dot) { dot = true; j++; }
                else break;
            }
            String tok = frame.substring(i, j);
            tok.replace(',', '.');
            result = tok.toFloat();
            found = true;
            i = j;
        } else {
            i++;
        }
    }
    return found ? result : NAN;
}

void beginScaleSerial(int optIdx) {
    ScaleSerial.end();
    delay(20);
    ScaleSerial.begin(scaleOptions[optIdx].baud, scaleOptions[optIdx].config,
                      PIN_SCALE_RX, PIN_SCALE_TX);
    ScaleSerial.setTimeout(100);
    delay(50);
}

// Escuta passiva: aguarda um frame completo (CR/LF/ETX) contendo um número.
// Detecta balanças em modo de transmissão contínua SEM enviar nada.
bool listenForFrame(unsigned long timeoutMs) {
    while (ScaleSerial.available()) ScaleSerial.read();
    String local = "";
    unsigned long start = millis();
    while (millis() - start < timeoutMs) {
        while (ScaleSerial.available()) {
            char c = (char)ScaleSerial.read();
            if (DEBUG_SCALE) Serial.printf("%02X ", (uint8_t)c);
            if (c == '\r' || c == '\n' || c == 0x03) {
                if (local.length() > 0 && !isnan(parseLastNumber(local))) return true;
                local = "";
            } else if (local.length() < 64) {
                local += c;
            } else {
                local = "";
            }
        }
    }
    return false;
}

// Interrogação ativa: limpa o buffer, envia o comando e aguarda resposta.
bool tryDetect(int cmdIdx, unsigned long timeoutMs) {
    while (ScaleSerial.available()) ScaleSerial.read();
    ScaleSerial.print(pollingCommands[cmdIdx]);
    String local = "";
    unsigned long start = millis();
    while (millis() - start < timeoutMs) {
        while (ScaleSerial.available()) {
            char c = (char)ScaleSerial.read();
            if (DEBUG_SCALE) Serial.printf("%02X ", (uint8_t)c);
            if (c == '\r' || c == '\n' || c == 0x03) {
                if (local.length() > 0 && !isnan(parseLastNumber(local))) return true;
                local = "";
            } else if (local.length() < 64) {
                local += c;
            } else {
                local = "";
            }
        }
    }
    return false;
}

void scaleDetected(int optIdx, int cmdIdx) {
    Serial.printf("\nBALANCA DETECTADA: %s (comando idx %d)\n",
                  scaleOptions[optIdx].label, cmdIdx);
    lcdMainPrint("BALANCA OK!", scaleOptions[optIdx].label);
    last_baud_idx = optIdx;
    last_cmd_idx = cmdIdx;
    preferences.begin("balanca-cfg", false);
    preferences.putInt("last_baud", optIdx);
    preferences.putInt("last_cmd", cmdIdx);
    preferences.end();
    scaleRxBuf = "";
    lastValidWeight = NAN;
    lastWeightMs = 0;
    lastByteRxMs = millis();
    delay(1000);
}

void autoConfigScale() {
    lcdMainPrint("BUSCANDO", "BALANCA...");
    lcdSecPrint("Aguarde...", "Scan Ativo");
    Serial.println("\n--- INICIANDO SCANNER DE BALANCA (v3) ---");

    int numOptions = sizeof(scaleOptions) / sizeof(scaleOptions[0]);

    // 1) Tenta primeiro a última configuração que funcionou
    if (last_baud_idx >= 0 && last_baud_idx < numOptions) {
        int cmd = (last_cmd_idx >= 0 && last_cmd_idx < numPollCommands) ? last_cmd_idx : 0;
        Serial.printf("Tentando config salva: %s\n", scaleOptions[last_baud_idx].label);
        lcdSecPrint("Ultima config:", scaleOptions[last_baud_idx].label);
        beginScaleSerial(last_baud_idx);
        if (listenForFrame(1500) || tryDetect(cmd, 1500)) {
            scaleDetected(last_baud_idx, cmd);
            return;
        }
    }

    // 2) Varredura completa (escuta passiva primeiro, depois interroga)
    for (int i = 0; i < numOptions; i++) {
        if (i == last_baud_idx) continue; // já testada acima
        Serial.printf("Escaneando: %s\n", scaleOptions[i].label);
        lcdSecPrint("Tentando:", scaleOptions[i].label);
        beginScaleSerial(i);

        if (listenForFrame(800)) {          // balança em modo contínuo
            scaleDetected(i, last_cmd_idx >= 0 ? last_cmd_idx : 0);
            return;
        }
        for (int j = 0; j < numPollCommands; j++) {
            if (tryDetect(j, 1000)) {       // balança em modo comando
                scaleDetected(i, j);
                return;
            }
        }
    }

    Serial.println("Nenhuma balanca detectada. Usando padrao 9600 8N1.");
    lcdMainPrint("FALHA DETECCAO", "Usando Padrao");
    last_baud_idx = 0;
    lastValidWeight = NAN;
    beginScaleSerial(0);
    delay(1000);
}

// Lê todos os bytes disponíveis SEM bloquear, fecha frames por CR/LF/ETX
// (ou por pausa > 150 ms) e mantém o último peso válido atualizado.
// Se a balança ficar em silêncio por 800 ms (modo comando), interroga —
// no máximo 1 comando a cada 400 ms (sem rajada).
void pumpScaleSerial() {
    while (ScaleSerial.available()) {
        char c = (char)ScaleSerial.read();
        lastByteRxMs = millis();
        if (c == '\r' || c == '\n' || c == 0x03) {
            if (scaleRxBuf.length() > 0) {
                float w = parseLastNumber(scaleRxBuf);
                if (DEBUG_SCALE) Serial.printf("[BALANCA] frame='%s'\n", scaleRxBuf.c_str());
                scaleRxBuf = "";
                if (!isnan(w)) {
                    lastValidWeight = w;
                    lastWeightMs = millis();

                    Serial.print("[BALANCA] PESO INTERPRETADO = ");
                    Serial.println(w, 3);
                }
            }
        } else if (scaleRxBuf.length() < 64) {
            scaleRxBuf += c;
        } else {
            scaleRxBuf = ""; // overflow de frame: descarta e ressincroniza
        }
    }

    // Fecha frame por pausa (protocolos sem terminador)
    if (scaleRxBuf.length() > 0 && millis() - lastByteRxMs > 150) {
        float w = parseLastNumber(scaleRxBuf);
        if (DEBUG_SCALE) Serial.printf("[BALANCA] frame(pausa)='%s'\n", scaleRxBuf.c_str());
        scaleRxBuf = "";
        if (!isnan(w)) {
            lastValidWeight = w;
            lastWeightMs = millis();
        }
    }

    // Interrogação: só se a balança estiver em silêncio (modo comando)
    if (millis() - lastByteRxMs > 800 && millis() - lastPollMs > 400) {
        lastPollMs = millis();
        int cmd = (last_cmd_idx >= 0 && last_cmd_idx < numPollCommands) ? last_cmd_idx : 0;
        ScaleSerial.print(pollingCommands[cmd]);
    }
}

// Retorna o último peso válido, ou NAN se não há leitura fresca (< 3 s).
float getWeightFromScale() {
    pumpScaleSerial();
    if (!isnan(lastValidWeight) && (millis() - lastWeightMs < 3000)) {
        return lastValidWeight;
    }
    return NAN;
}

void tareScaleSerial() {
    lcdMainPrint("TARANDO...", "Aguarde...");
    lcdSecPrint("Nao toque na", "balanca");
    lastValidWeight = NAN;
    ScaleSerial.write('T');
    ScaleSerial.write('Z');
    ScaleSerial.print("\r\n"); // Algumas pedem terminador na tara
    delay(1500);
}

void saveConfigCallback() {
    Serial.println("Config salva.");
    shouldSaveConfig = true;
}

// Protótipos de Funções de Estado
void setupWiFiManager();
void setupMQTT();
void state_waitForCard();
void state_cardAuth();
void state_showCardError();
void state_confirmUser();
void state_selectPackage();
void state_selectWeight();
void state_confirmWeighStart();
void state_weighingLoop();
void state_weighingSuccess();
void state_weighingError();
void state_sendingReport();
void state_reportError();

// 5. SETUP
void setup() {
    Serial.begin(115200);
    Serial.println("\n\n--- INICIANDO SISTEMA (v3) ---");

    pinMode(PIN_BTN_CONFIRMAR, INPUT_PULLUP);
    pinMode(PIN_BTN_CANCELAR, INPUT_PULLUP);
    pinMode(PIN_BTN_SETA_CIMA, INPUT_PULLUP);
    pinMode(PIN_BTN_SETA_BAIXO, INPUT_PULLUP);
    pinMode(PIN_BTN_FINALIZAR, INPUT_PULLUP);

    pinMode(PIN_LED_VERMELHO, OUTPUT);
    pinMode(PIN_LED_VERDE, OUTPUT);
    digitalWrite(PIN_LED_VERDE, HIGH); delay(500);
    digitalWrite(PIN_LED_VERDE, LOW);

    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
    Wire.setClock(100000);
    lcd_main.begin(16, 2);
    lcd_sec.begin(16, 2);
    lcdMainPrint("INICIANDO...", "Carregando...");

    SPI.begin(PIN_RFID_SCK, PIN_RFID_MISO, PIN_RFID_MOSI, PIN_RFID_SS);
    delay(500);
    rfid.PCD_Init();

    preferences.begin("balanca-cfg", false);
    board_position = preferences.getString("bancada", "1");
    last_baud_idx = preferences.getInt("last_baud", -1); // Recupera última baud rate
    last_cmd_idx  = preferences.getInt("last_cmd", -1);  // Recupera último comando
    String s_broker = preferences.getString("mqtt_broker", DEFAULT_BROKER);
    String s_port = preferences.getString("mqtt_port", DEFAULT_PORT);
    String s_user = preferences.getString("mqtt_user", DEFAULT_USER);
    String s_pass = preferences.getString("mqtt_pass", DEFAULT_PASS);

    s_broker.toCharArray(mqtt_broker, 100);
    s_port.toCharArray(mqtt_port, 6);
    s_user.toCharArray(mqtt_user, 40);
    s_pass.toCharArray(mqtt_pass, 40);
    preferences.end();

    setupWiFiManager();
    espClient.setInsecure();
    configTime(GMT_OFFSET_SEC, 0, NTP_SERVER);
    setupMQTT();

    //const char *headerKeys[] = {"Set-Cookie", "Cookie"};
    //http.collectHeaders(headerKeys, 2);

    String hardwareID = getChipID();
    Serial.println("\n============================");
    Serial.print("HARDWARE ID: "); Serial.println(hardwareID);
    Serial.print("ID BANCADA (Configurada): "); Serial.println(board_position);
    Serial.println("============================");

    lcdMainPrint("ID PLACA:", hardwareID);
    lcdSecPrint("ID: " + board_position, "Aguarde");
    digitalWrite(PIN_LED_VERDE, HIGH); delay(3000);
    digitalWrite(PIN_LED_VERDE, LOW);

    currentState = STATE_WAIT_FOR_CARD;
}

void setupWiFiManager() {
    WiFiManager wm;
    wm.setSaveConfigCallback(saveConfigCallback);
    wm.setConnectTimeout(40);
    lcdMainPrint("CONF. WIFI", "Busque a Rede:");
    lcdSecPrint("ESP32-Pesagem", "Buscando....");

    WiFiManagerParameter custom_board_pos("bancada", "ID Bancada", board_position.c_str(), 40);
    WiFiManagerParameter custom_mqtt_server("server", "MQTT Broker", mqtt_broker, 100);
    WiFiManagerParameter custom_mqtt_port("port", "MQTT Port", mqtt_port, 6);
    WiFiManagerParameter custom_mqtt_user("user", "MQTT User", mqtt_user, 40);
    WiFiManagerParameter custom_mqtt_pass("pass", "MQTT Pass", mqtt_pass, 40);

    wm.addParameter(&custom_board_pos);
    wm.addParameter(&custom_mqtt_server);
    wm.addParameter(&custom_mqtt_port);
    wm.addParameter(&custom_mqtt_user);
    wm.addParameter(&custom_mqtt_pass);

    if (!wm.autoConnect("ESP32-Pesagem", AP_PASSWORD_PROTECTION)) {
        Serial.println("Falha ao conectar. Reiniciando...");
        lcdMainPrint("FALHA WIFI", "Reiniciando...");
        delay(2000);
        ESP.restart();
    }

    lcdMainPrint("WIFI CONECTADO!", "Configurando...");
    if (shouldSaveConfig) {
        board_position = custom_board_pos.getValue();
        strcpy(mqtt_broker, custom_mqtt_server.getValue());
        strcpy(mqtt_port, custom_mqtt_port.getValue());
        strcpy(mqtt_user, custom_mqtt_user.getValue());
        strcpy(mqtt_pass, custom_mqtt_pass.getValue());

        preferences.begin("balanca-cfg", false);
        preferences.putString("bancada", board_position);
        preferences.putString("mqtt_broker", mqtt_broker);
        preferences.putString("mqtt_port", mqtt_port);
        preferences.putString("mqtt_user", mqtt_user);
        preferences.putString("mqtt_pass", mqtt_pass);
        preferences.end();
    }
}

void setupMQTT() {
    String hardwareID = getChipID();
    MQTT_CLIENT_ID = hardwareID;
    MQTT_TOPIC_STATUS = "balanca/status";
    payloadOnline = "{\"id\":\"" + hardwareID + "\", \"status\":\"online\"}";
    payloadOffline = "{\"id\":\"" + hardwareID + "\", \"status\":\"offline\"}";

    int port_int = atoi(mqtt_port);
    mqttClient.setServer(mqtt_broker, port_int);
    mqttClient.setBufferSize(1024);
    mqttClient.setKeepAlive(20);
    mqttClient.setSocketTimeout(5); // evita travamento longo do loop no reconnect TLS

    if (mqttClient.connect(MQTT_CLIENT_ID.c_str(), mqtt_user, mqtt_pass, MQTT_TOPIC_STATUS.c_str(), 1, true, payloadOffline.c_str())) {
        mqttClient.publish(MQTT_TOPIC_STATUS.c_str(), payloadOnline.c_str(), true);
    }
}

void loop() {
    if (WiFi.status() == WL_CONNECTED && !mqttClient.connected()) {
        static unsigned long lastReconnectAttempt = 0;
        if (millis() - lastReconnectAttempt > 5000) {
            lastReconnectAttempt = millis();
            if (mqttClient.connect(MQTT_CLIENT_ID.c_str(), mqtt_user, mqtt_pass, MQTT_TOPIC_STATUS.c_str(), 1, true, payloadOffline.c_str())) {
                mqttClient.publish(MQTT_TOPIC_STATUS.c_str(), payloadOnline.c_str(), true);
            }
        }
    }
    mqttClient.loop();

    switch (currentState) {
        case STATE_WAIT_FOR_CARD: state_waitForCard(); break;
        case STATE_CARD_AUTH: state_cardAuth(); break;
        case STATE_SHOW_CARD_ERROR: state_showCardError(); break;
        case STATE_CONFIRM_USER: state_confirmUser(); break;
        case STATE_SELECT_PACKAGE: state_selectPackage(); break;
        case STATE_SELECT_WEIGHT: state_selectWeight(); break;
        case STATE_CONFIRM_WEIGH_START: state_confirmWeighStart(); break;
        case STATE_WEIGHING_LOOP: state_weighingLoop(); break;
        case STATE_WEIGHING_SUCCESS: state_weighingSuccess(); break;
        case STATE_WEIGHING_ERROR: state_weighingError(); break;
        case STATE_SENDING_REPORT: state_sendingReport(); break;
        case STATE_REPORT_ERROR: state_reportError(); break;
        default: break;
    }
}

void state_waitForCard() {
    lcdMainPrint("APROXIME CARTAO", "P/ INICIAR...");
    lcdSecPrint("Local: " + board_position, "Livre");
    setLeds(false, false);
    String card = readRFID();
    if (card != "") {
        last_card_id = card;
        lcdMainPrint("LENDO ID:", last_card_id);
        lcdSecPrint("Verificando...", "Aguarde");
        digitalWrite(PIN_LED_VERDE, HIGH); delay(100);
        digitalWrite(PIN_LED_VERDE, LOW);
        delay(1000);
        currentState = STATE_CARD_AUTH;
    }
}

void state_cardAuth() {
    Serial.println("\n--- AUTH (GET) ---");
    if (WiFi.status() != WL_CONNECTED) {
        lcdMainPrint("SEM WIFI", "ID:" + last_card_id);
        delay(3000);
        currentState = STATE_WAIT_FOR_CARD;
        return;
    }
    last_card_id.trim();
    String fullUrl = String(URL_BASE) + "/" + last_card_id;
    http.setTimeout(10000);
    http.begin(fullUrl);

    const char *headerKeys[] = {"Set-Cookie"};
    http.collectHeaders(headerKeys, 1);

    http.addHeader("Accept", "application/json");
    http.addHeader("User-Agent", "ESP32");

    int httpCode = http.GET();
    if (httpCode == 200) {
        String payload = http.getString();

        // Verificar a resposta da API para comparar com
        // os dados registrados e ver se bate com o peso META
        Serial.println("\n========== API RESPONSE ==========");
        Serial.println(payload);
        Serial.println("==================================");
        
        
        if (http.hasHeader("Set-Cookie")) {
            globalCookie = http.header("Set-Cookie");
            Serial.print("Cookie OK: ");
            Serial.println(globalCookie);
        } else {
            Serial.println("AVISO: Set-Cookie nao recebido!");
        
        }

        Serial.println("========== COOKIE AUTH ==========");
        Serial.print("globalCookie = [");
        Serial.print(globalCookie);
        Serial.println("]");
        Serial.print("Cookie length = ");
        Serial.println(globalCookie.length());
        Serial.println("=================================");
        
        JsonDocument docLocal;
        DeserializationError error = deserializeJson(docLocal, payload);
        if (!error) {
            employee_name = docLocal["employee_name"] | "Funcionario";
            employee_data = docLocal;
            JsonArray packages = employee_data["packages"].as<JsonArray>();
            if (packages.size() > 0) {
                currentState = STATE_CONFIRM_USER;
            } else {
                lcdMainPrint("SEM PACOTES", "ID:" + last_card_id);
                delay(3000);
                currentState = STATE_WAIT_FOR_CARD;
            }
        } else {
            lcdMainPrint("ERRO JSON", "Tente Novamente");
            delay(3000);
            currentState = STATE_WAIT_FOR_CARD;
        }
    } else if (httpCode == 404) {
        lcdMainPrint("NAO RECONHECIDO", "Verifique ID");
        delay(4000);
        currentState = STATE_WAIT_FOR_CARD;
    } else {
        lcdMainPrint("ERRO: " + String(httpCode), "Tente Novamente");
        setLeds(false, true);
        delay(4000);
        currentState = STATE_WAIT_FOR_CARD;
    }
    http.end();
}

void state_showCardError() { currentState = STATE_WAIT_FOR_CARD; }

void state_confirmUser() {
    lcdMainPrint("Ola,", employee_name);
    lcdSecPrint("1:CONFIRMAR", "2:CANCELAR");
    if (readButton(PIN_BTN_CONFIRMAR)) { menu_index_pkg = 0; currentState = STATE_SELECT_PACKAGE; delay(300); }
    if (readButton(PIN_BTN_CANCELAR)) { currentState = STATE_WAIT_FOR_CARD; delay(300); }
}

void state_selectPackage() {
    JsonArray packages = employee_data["packages"].as<JsonArray>();
    int num_packages = packages.size();
    String pkgName = packages[menu_index_pkg]["name"].as<String>();
    lcdMainPrint("PCT:", pkgName);
    lcdSecPrint(String(menu_index_pkg + 1) + "/" + String(num_packages) + " NAV: Setas", "1:OK 2:VOLT");

    if (readButton(PIN_BTN_SETA_CIMA)) { menu_index_pkg = (menu_index_pkg - 1 < 0) ? num_packages - 1 : menu_index_pkg - 1; delay(250); }
    if (readButton(PIN_BTN_SETA_BAIXO)) { menu_index_pkg = (menu_index_pkg + 1 >= num_packages) ? 0 : menu_index_pkg + 1; delay(250); }
    if (readButton(PIN_BTN_CONFIRMAR)) {
        selected_package.name = pkgName;
        selected_package.tolerance = packages[menu_index_pkg]["tolerance"].as<float>();
        menu_index_wgt = 0;
        currentState = STATE_SELECT_WEIGHT;
        delay(300);
    }
    if (readButton(PIN_BTN_CANCELAR)) { currentState = STATE_WAIT_FOR_CARD; delay(300); }
}

void state_selectWeight() {
    JsonArray weights =
        employee_data["packages"][menu_index_pkg]["weight"].as<JsonArray>();

    int num_weights = weights.size();

    Serial.println("\n========== META ==========");
    Serial.print("Quantidade de metas: ");
    Serial.println(num_weights);

    if (num_weights <= 0) {
        Serial.println("ERRO: nenhuma META encontrada na API.");

        lcdMainPrint("ERRO META", "Nao encontrada");
        lcdSecPrint("Verifique a API", "");

        delay(3000);

        currentState = STATE_SELECT_PACKAGE;
        return;
    }

    if (menu_index_wgt >= num_weights) {
        menu_index_wgt = 0;
    }

    float wVal = weights[menu_index_wgt].as<float>();

    Serial.print("META selecionada: ");
    Serial.println(wVal, 3);

    lcdMainPrint("PESO REF:", String(wVal, 3) + "kg");
    lcdSecPrint("1: SELECIONAR", "2:VOLTAR");

    if (readButton(PIN_BTN_SETA_CIMA)) {
        menu_index_wgt =
            (menu_index_wgt - 1 < 0)
            ? num_weights - 1
            : menu_index_wgt - 1;

        delay(250);
    }

    if (readButton(PIN_BTN_SETA_BAIXO)) {
        menu_index_wgt =
            (menu_index_wgt + 1 >= num_weights)
            ? 0
            : menu_index_wgt + 1;

        delay(250);
    }

    if (readButton(PIN_BTN_CONFIRMAR)) {
        selected_package.weight = wVal;
        currentState = STATE_CONFIRM_WEIGH_START;
        delay(300);
    }

    if (readButton(PIN_BTN_CANCELAR)) {
        currentState = STATE_SELECT_PACKAGE;
        delay(300);
    }
}

void state_confirmWeighStart() {
    lcdMainPrint("INICIAR SEQ?", String(selected_package.weight, 3) + "kg");
    lcdSecPrint("1:SIM | 2:NAO", "");
    if (readButton(PIN_BTN_CONFIRMAR)) {
        session_start_time_epoch = getTimestampEpoch();
        total_weight_session = 0.0;
        package_count_session = 0;
        display_weight = 0.0;
        autoConfigScale();
        //tareScaleSerial();
        currentState = STATE_WEIGHING_LOOP;
        delay(300);
    }
    if (readButton(PIN_BTN_CANCELAR)) { currentState = STATE_SELECT_WEIGHT; delay(300); }
}

void state_weighingLoop() {
    float current_weight = getWeightFromScale();
    if (!isnan(current_weight)) display_weight = current_weight;

    // Redesenha o LCD apenas quando algo mudou (sem flicker e sem
    // desperdiçar o loop com I2C a cada iteração)
    static float lastShown = -99999.0;
    static int lastShownCount = -1;
    if (fabsf(display_weight - lastShown) > 0.0005f || package_count_session != lastShownCount) {
        lastShown = display_weight;
        lastShownCount = package_count_session;
        lcdMainPrint("PESO: " + String(display_weight, 3) + "kg", "META: " + String(selected_package.weight, 3) + "kg");
        lcdSecPrint("QTD: " + String(package_count_session) + "| Tot:" + String((int)total_weight_session), "1:GRAVAR 3:FIM");
    }
    setLeds(false, false);

    if (readButton(PIN_BTN_CONFIRMAR)) {
        float min_w = selected_package.weight;
        float max_w = selected_package.weight + selected_package.tolerance;
        if (display_weight >= min_w && display_weight <= max_w) {
            total_weight_session += display_weight;
            package_count_session++;
            currentState = STATE_WEIGHING_SUCCESS;
        } else {
            currentState = STATE_WEIGHING_ERROR;
        }
        delay(500);
    }
    if (readButton(PIN_BTN_FINALIZAR)) {
        session_end_time_epoch = getTimestampEpoch();
        currentState = STATE_SENDING_REPORT;
        delay(300);
    }
}

void state_weighingSuccess() {
    lcdMainPrint("SUCESSO!", "Peso Registrado");
    lcdSecPrint("QTD Total: " + String(package_count_session), "Remova o Peso");
    setLeds(true, false);
    delay(2000);
    unsigned long s = millis();
    while (millis() - s < 8000) {
        float w = getWeightFromScale();
        if (!isnan(w) && w <= 0.05) break; // peso removido
        lcdSecPrint("Remova o Peso", "da Balanca...");
        delay(100);
    }
    currentState = STATE_WEIGHING_LOOP;
}

void state_weighingError() {
    lcdMainPrint("ERRO: PESO", "FORA TOLERANCIA");
    lcdSecPrint("Esperado: " + String(selected_package.weight, 3), "Tol: " + String(selected_package.tolerance, 3));
    setLeds(false, true);
    delay(3000);
    currentState = STATE_WEIGHING_LOOP;
}

void state_sendingReport() {
    lcdMainPrint("ENVIANDO DADOS", "Aguarde...");
    JsonDocument doc_rep;
    String hardwareID = getChipID();
    doc_rep["terminal_id"] = hardwareID;
    doc_rep["employee_id"] = last_card_id;
    doc_rep["employee_name"] = employee_name;

    JsonObject pkgObj = doc_rep.createNestedObject("package");
    pkgObj["name"] = selected_package.name;
    pkgObj["weight"] = selected_package.weight;
    pkgObj["quantity"] = package_count_session;
    pkgObj["tolerance"] = selected_package.tolerance;

    doc_rep["total_weight"] = total_weight_session;
    if (session_end_time_epoch == 0) session_end_time_epoch = getTimestampEpoch();

    char timeBuff[35];
    time_t t_start = (time_t)session_start_time_epoch;
    struct tm *tm_start = localtime(&t_start);
    strftime(timeBuff, sizeof(timeBuff), "%Y-%m-%dT%H:%M:%S", tm_start);
    doc_rep["timestamp_begin"] = String(timeBuff);

    time_t t_end = (time_t)session_end_time_epoch;
    struct tm *tm_end = localtime(&t_end);
    strftime(timeBuff, sizeof(timeBuff), "%Y-%m-%dT%H:%M:%S", tm_end);
    doc_rep["timestamp_end"] = String(timeBuff);

    String jsonReq;
    serializeJson(doc_rep, jsonReq);
    
    http.begin(String(URL_BASE));
    http.setTimeout(10000); // Volte com o timeout do código 1 para evitar quedas
    http.addHeader("Content-Type", "application/json");
    http.addHeader("User-Agent", "ESP32"); // <-- ESSA É A LINHA QUE FALTAVA

if (globalCookie.length() > 0) {
    http.addHeader("Cookie", globalCookie);
}
    
    Serial.println("\n========== ENVIO PESAGEM ==========");
    Serial.println("URL:");
    Serial.println(String(URL_BASE));
    
    Serial.print("COOKIE ENVIADO: [");
    Serial.print(globalCookie);
    Serial.println("]");
    
    Serial.print("COOKIE LENGTH: ");
    Serial.println(globalCookie.length());
    
    Serial.println("JSON ENVIADO:");
    Serial.println(jsonReq);
    
    Serial.print("Cookie enviado = [");
    Serial.print(globalCookie);
    Serial.println("]");

    if (globalCookie.length() > 0) {
        http.addHeader("Cookie", globalCookie);
    }
    
    int httpCode = http.POST(jsonReq);
    
    Serial.print("HTTP CODE: ");
    Serial.println(httpCode);
    
    if (httpCode > 0) {
        String response = http.getString();
        Serial.println("RESPOSTA DO SERVIDOR:");
        Serial.println(response);
    }
    
    Serial.println("==================================");

    if (httpCode == 200 || httpCode == 201) {
        lcdMainPrint("DADOS ENVIADOS", "SUCESSO (" + String(httpCode) + ")");
    } else {
        lcdMainPrint("FALHA ENVIO", "Erro: " + String(httpCode));
    }
    delay(4000);
    http.end();
    session_end_time_epoch = 0;
    currentState = STATE_WAIT_FOR_CARD;
}

void state_reportError() { currentState = STATE_WAIT_FOR_CARD; }
