/*
 * TESTE UNITÁRIO: Leitura Serial da Balança
 * Hardware: ESP32 + Conversor RS232/TTL
 * Pinos: RX=16, TX=17
 * Baud Rate: 9600
 */

#include <HardwareSerial.h>

#define PIN_SCALE_RX      16
#define PIN_SCALE_TX      17
#define SCALE_BAUD_RATE   9600
#define SCALE_SERIAL_CONFIG SERIAL_8N1

HardwareSerial ScaleSerial(2); // UART2

void setup() {
  Serial.begin(115200);
  Serial.println("\n--- INICIANDO TESTE DA BALANCA ---");
  Serial.println("Lendo dados brutos da UART2 (Pino 16)...");

  ScaleSerial.begin(SCALE_BAUD_RATE, SCALE_SERIAL_CONFIG, PIN_SCALE_RX, PIN_SCALE_TX);
}

void loop() {
  // Pass-through: O que vier da balança, joga no monitor serial do PC
  if (ScaleSerial.available()) {
    char c = ScaleSerial.read();
    
    // Debug visual: mostra caracteres normais, mas destaca terminadores
    if (c == '\r') Serial.print("[CR]");
    else if (c == '\n') Serial.println("[LF]");
    else Serial.print(c);
  }
  
  // (Opcional) Enviar comandos do PC para a balança (Ex: Tarar)
  if (Serial.available()) {
    ScaleSerial.write(Serial.read());
  }
}