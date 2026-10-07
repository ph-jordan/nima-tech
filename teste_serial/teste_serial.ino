#include <HardwareSerial.h>

// Definições de hardware baseadas na sua placa 
#define PIN_SCALE_RX 17
#define PIN_SCALE_TX 16

HardwareSerial ScaleSerial(2);

// Velocidades e Configurações de Paridade
long bauds[] = {9600, 4800, 2400};
uint32_t configs[] = {SERIAL_8N1, SERIAL_7E1, SERIAL_8E1, SERIAL_7O1};
const char* configLabels[] = {"8N1", "7E1", "8E1", "7O1"};

// Comandos de Polling (Interrogação)
const char* pollCmds[] = {"P", "W", "\x05", "\r", "READ\r\n"}; 

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("\n========================================");
  Serial.println("   SCANNER DE DIAGNOSTICO DE BALANCA    ");
  Serial.println("========================================");
  Serial.println("Pinos: RX=17, TX=16 | Sem WiFi/Interrupções");
}

void loop() {
  for (int b = 0; b < 3; b++) {
    for (int c = 0; c < 4; c++) {
      Serial.printf("\n>>> TESTANDO: %ld bps | %s <<<\n", bauds[b], configLabels[c]);
      
      ScaleSerial.begin(bauds[b], configs[c], PIN_SCALE_RX, PIN_SCALE_TX);
      delay(500);

      // 1. TESTE DE STREAMING (Escuta passiva)
      Serial.println("Checking Streaming (3s)...");
      unsigned long start = millis();
      bool receivedStream = false;
      while (millis() - start < 3000) {
        if (ScaleSerial.available()) {
          showRawData();
          receivedStream = true;
        }
      }
      if (!receivedStream) Serial.println(" [!] Sem dados em modo Stream.");

      // 2. TESTE DE POLLING (Interrogação ativa)
      for (int j = 0; j < 5; j++) {
        Serial.printf("Checking Polling (Cmd: '%s')...\n", pollCmds[j]);
        while (ScaleSerial.available()) ScaleSerial.read(); // Limpa buffer
        ScaleSerial.print(pollCmds[j]);
        
        start = millis();
        bool receivedPoll = false;
        while (millis() - start < 2000) {
          if (ScaleSerial.available()) {
            showRawData();
            receivedPoll = true;
          }
        }
        if (!receivedPoll) Serial.println("  [!] Sem resposta ao comando.");
      }

      ScaleSerial.end();
      Serial.println("----------------------------------------");
    }
  }
  Serial.println("\nFim do ciclo de scan. Reiniciando em 5 segundos...");
  delay(5000);
}

// Função para mostrar o dado bruto e em Hexadecimal
void showRawData() {
  while (ScaleSerial.available()) {
    char raw = ScaleSerial.read();
    if (isprint(raw)) {
      Serial.printf("  DATA: %c  | HEX: 0x%02X\n", raw, raw);
    } else {
      Serial.printf("  NON-PRINT | HEX: 0x%02X\n", raw);
    }
  }
}