/*
 * TESTE UNITÁRIO: RFID MFRC522 (SPI)
 * Hardware: ESP32 + MFRC522
 * Pinos: SS=5, SCK=18, MISO=19, MOSI=23, RST=4
 * ALERTA: GPIO 5 pode impedir o boot se estiver LOW na inicialização.
 * GPIO 5 é um pino de Strapping.
 */

#include <SPI.h>
#include <MFRC522.h>

#define PIN_RFID_SS   5
#define PIN_RFID_SCK  18
#define PIN_RFID_MISO 19
#define PIN_RFID_MOSI 23
#define PIN_RFID_RST  4

MFRC522 rfid(PIN_RFID_SS, PIN_RFID_RST);

void setup() {
  Serial.begin(115200);
  while (!Serial); 
  
  Serial.println("\n--- INICIANDO TESTE RFID ---");
  
  SPI.begin(PIN_RFID_SCK, PIN_RFID_MISO, PIN_RFID_MOSI, PIN_RFID_SS);
  rfid.PCD_Init();
  
  // Diagnóstico de versão do firmware do chip MFRC522
  // Se retornar 0x00 ou 0xFF, há erro de comunicação/fios
  rfid.PCD_DumpVersionToSerial();
  Serial.println("Aguardando cartao...");
}

void loop() {
  // Verifica se há novo cartão
  if ( ! rfid.PICC_IsNewCardPresent()) return;
  if ( ! rfid.PICC_ReadCardSerial()) return;

  Serial.print("UID Detectado: ");
  String card_id = "";
  for (byte i = 0; i < rfid.uid.size; i++) {
    Serial.print(rfid.uid.uidByte[i] < 0x10 ? " 0" : " ");
    Serial.print(rfid.uid.uidByte[i], HEX);
    card_id += (rfid.uid.uidByte[i] < 0x10 ? "0" : "");
    card_id += String(rfid.uid.uidByte[i], HEX);
  }
  Serial.println();
  
  card_id.toUpperCase();
  Serial.print("String Formatada: ");
  Serial.println(card_id);
  
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
  delay(1000); // Pausa para não ler o mesmo cartão instantaneamente
}