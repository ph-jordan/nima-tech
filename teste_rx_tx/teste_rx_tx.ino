#include <HardwareSerial.h>

#define PIN_SCALE_RX 17
#define PIN_SCALE_TX 16

HardwareSerial ScaleSerial(2);

void setup() {
  Serial.begin(115200);
  delay(2000);
  
  Serial.println("\n=== TESTE DE INVERSÃO RX/TX ===\n");
  
  // Teste 1: Com RX=17, TX=16 (configuração atual)
  testarOrientacao(17, 16, "ATUAL (RX=17, TX=16)");
  delay(2000);
  
  // Teste 2: Invertido
  testarOrientacao(16, 17, "INVERTIDO (RX=16, TX=17)");
}

void testarOrientacao(int rx, int tx, const char* label) {
  Serial.printf("\n>>> %s <<<\n", label);
  
  ScaleSerial.end();
  ScaleSerial.begin(9600, SERIAL_8N1, rx, tx); // Começa com 9600
  delay(300);
  
  Serial.println("Escutando por 3 segundos...");
  unsigned long start = millis();
  int bytesRecebidos = 0;
  
  while (millis() - start < 3000) {
    if (ScaleSerial.available()) {
      byte b = ScaleSerial.read();
      Serial.printf("0x%02X ", b);
      bytesRecebidos++;
      
      // Se começar a receber dados, já indica sucesso!
      if (bytesRecebidos > 5) {
        Serial.printf("\n✓ SUCESSO! Recebeu %d bytes em %s\n", 
                      bytesRecebidos, label);
        return;
      }
    }
  }
  
  Serial.printf("\n✗ Nenhum dado recebido em %s\n", label);
}

void loop() {} // Vazio - teste roda uma vez no setup