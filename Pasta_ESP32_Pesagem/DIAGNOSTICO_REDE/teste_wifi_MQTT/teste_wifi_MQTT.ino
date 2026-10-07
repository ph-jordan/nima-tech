/*
 * TESTE UNITÁRIO: Conectividade WiFi e MQTT (SSL/TLS)
 * Hardware: ESP32
 * Bibliotecas: WiFiManager (tzapu), PubSubClient, ArduinoJson
 * * OBJETIVO: 
 * 1. Testar o portal cativo (WiFiManager).
 * 2. Validar a gravação de parametros na memória (Preferences).
 * 3. Testar conexão segura (TLS) com o Broker MQTT.
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <Preferences.h>

// --- Configuração de Hardware (LEDs de Status) ---
#define PIN_LED_VERDE     12 // Aceso = Conectado e Operacional
#define PIN_LED_VERMELHO  13 // Aceso/Piscando = Tentando conectar ou Erro

// --- Valores Padrão (Caso a memória esteja vazia) ---
const char* DEFAULT_BROKER = "6df66d562a2e4bbdb0555f70df83a04d.s1.eu.hivemq.cloud";
const char* DEFAULT_PORT   = "8883"; // Porta SSL padrão
const char* DEFAULT_USER   = "Samuel";
const char* DEFAULT_PASS   = "Telecom25";

// --- Variáveis Globais ---
char mqtt_broker[100];
char mqtt_port[6];
char mqtt_user[40];
char mqtt_pass[40];

bool shouldSaveConfig = false;

// Objetos
WiFiClientSecure espClient;
PubSubClient mqttClient(espClient);
Preferences preferences;

// Callback para notificar que houve alterações no WiFiManager
void saveConfigCallback () {
  Serial.println("[CALLBACK] Alterações detectadas no Portal. Preparando para guardar...");
  shouldSaveConfig = true;
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED_VERDE, OUTPUT);
  pinMode(PIN_LED_VERMELHO, OUTPUT);
  
  // Estado inicial: LEDs apagados
  digitalWrite(PIN_LED_VERDE, LOW);
  digitalWrite(PIN_LED_VERMELHO, HIGH); // Vermelho indica "A iniciar/Desconectado"

  Serial.println("\n--- INICIANDO TESTE DE CONECTIVIDADE ---");

  // 1. Ler configurações salvas na memória NVS
  Serial.println("Lendo preferencias...");
  preferences.begin("balanca-cfg", false);
  
  String s_broker = preferences.getString("mqtt_broker", DEFAULT_BROKER);
  String s_port   = preferences.getString("mqtt_port", DEFAULT_PORT);
  String s_user   = preferences.getString("mqtt_user", DEFAULT_USER);
  String s_pass   = preferences.getString("mqtt_pass", DEFAULT_PASS);

  s_broker.toCharArray(mqtt_broker, 100);
  s_port.toCharArray(mqtt_port, 6);
  s_user.toCharArray(mqtt_user, 40);
  s_pass.toCharArray(mqtt_pass, 40);
  
  preferences.end();
  
  Serial.print("Broker Atual: "); Serial.println(mqtt_broker);

  // 2. Configurar WiFiManager
  WiFiManager wm;
  wm.setSaveConfigCallback(saveConfigCallback);
  
  // Parâmetros personalizados no portal
  WiFiManagerParameter custom_mqtt_server("server", "MQTT Broker", mqtt_broker, 100);
  WiFiManagerParameter custom_mqtt_port("port", "MQTT Port", mqtt_port, 6);
  WiFiManagerParameter custom_mqtt_user("user", "MQTT User", mqtt_user, 40);
  WiFiManagerParameter custom_mqtt_pass("pass", "MQTT Pass", mqtt_pass, 40, "type='password'");

  wm.addParameter(&custom_mqtt_server);
  wm.addParameter(&custom_mqtt_port);
  wm.addParameter(&custom_mqtt_user);
  wm.addParameter(&custom_mqtt_pass);

  // Se não conectar, cria o AP "ESP-TESTE-REDE"
  wm.setTimeout(180); // 3 minutos para configurar antes de reiniciar
  
  Serial.println("Conectando ao WiFi... (ou criando AP se falhar)");
  
  if (!wm.autoConnect("ESP-TESTE-REDE", "Admin1234")) {
    Serial.println("Falha na conexão ou timeout. Reiniciando...");
    ESP.restart();
  }

  // 3. Salvar novas configurações se foram alteradas
  if (shouldSaveConfig) {
    strcpy(mqtt_broker, custom_mqtt_server.getValue());
    strcpy(mqtt_port, custom_mqtt_port.getValue());
    strcpy(mqtt_user, custom_mqtt_user.getValue());
    strcpy(mqtt_pass, custom_mqtt_pass.getValue());

    Serial.println("Salvando novas configs na NVS...");
    preferences.begin("balanca-cfg", false);
    preferences.putString("mqtt_broker", mqtt_broker);
    preferences.putString("mqtt_port", mqtt_port);
    preferences.putString("mqtt_user", mqtt_user);
    preferences.putString("mqtt_pass", mqtt_pass);
    preferences.end();
  }

  Serial.println("WiFi Conectado!");
  Serial.print("IP: "); Serial.println(WiFi.localIP());

  // 4. Configurar MQTT Seguro
  // IMPORTANTE: setInsecure() permite conexão SSL sem validar certificado CA.
  // Para produção estrita, deveria usar setCACert(), mas para HiveMQ cloud free, isso facilita.
  espClient.setInsecure(); 
  
  int port_int = atoi(mqtt_port);
  mqttClient.setServer(mqtt_broker, port_int);
}

void loop() {
  // Verifica conexão MQTT
  if (!mqttClient.connected()) {
    digitalWrite(PIN_LED_VERDE, LOW);
    digitalWrite(PIN_LED_VERMELHO, HIGH);
    reconnectMQTT();
  } else {
    digitalWrite(PIN_LED_VERDE, HIGH);
    digitalWrite(PIN_LED_VERMELHO, LOW);
    mqttClient.loop();
    
    // Envia heartbeat a cada 5 segundos
    static unsigned long lastMsg = 0;
    if (millis() - lastMsg > 5000) {
      lastMsg = millis();
      String msg = "Teste conectividade: " + String(millis()/1000) + "s";
      Serial.print("Publicando: "); Serial.println(msg);
      
      // Tópico de teste genérico
      mqttClient.publish("balanca/teste/debug", msg.c_str());
    }
  }
}

void reconnectMQTT() {
  // Loop até conectar
  if (!mqttClient.connected()) {
    Serial.print("Tentando conexão MQTT...");
    
    String clientId = "ESP32-Teste-" + String(random(0xffff), HEX);
    
    if (mqttClient.connect(clientId.c_str(), mqtt_user, mqtt_pass)) {
      Serial.println("CONECTADO!");
      mqttClient.publish("balanca/teste/status", "Online - Script de Teste");
    } else {
      Serial.print("Falha, rc=");
      Serial.print(mqttClient.state());
      Serial.println(" tentando novamente em 5s");
      delay(5000);
    }
  }
}