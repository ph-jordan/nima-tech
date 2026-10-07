/*
 * TESTE UNITÁRIO: I2C Scanner & LCD (Versão hd44780)
 * Hardware: ESP32 + 2x LCD 16x2
 * Pinos: SDA = 21, SCL = 22
 */

#include <Wire.h>
#include <hd44780.h>                       // Camada principal
#include <hd44780ioClass/hd44780_I2Cexp.h> // Camada I2C expander

#define PIN_I2C_SDA 21
#define PIN_I2C_SCL 22

// Definição dos objetos com endereço fixo
// Na hd44780, passamos o endereço aqui. As colunas/linhas vão no begin().
hd44780_I2Cexp lcd_main(0x27);
hd44780_I2Cexp lcd_sec(0x28);

void setup() {
  Serial.begin(115200);
  while (!Serial); // Aguarda serial (útil em alguns ESPs)
  Serial.println("\n--- INICIANDO TESTE I2C (LIB: hd44780) ---");

  // Inicia o barramento I2C nos pinos corretos da ESP32
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);

  // 1. Scanner de Endereços (Isso usa a biblioteca Wire pura, continua igual)
  byte error, address;
  int nDevices = 0;

  Serial.println("Varrendo barramento...");
  for(address = 1; address < 127; address++ ) {
    Wire.beginTransmission(address);
    error = Wire.endTransmission();
    if (error == 0) {
      Serial.print("Dispositivo I2C encontrado no endereco: 0x");
      if (address < 16) Serial.print("0");
      Serial.print(address, HEX);
      Serial.println("  !");
      nDevices++;
    }
  }
  
  if (nDevices == 0) Serial.println("Nenhum dispositivo I2C encontrado.\n");
  else Serial.println("Varredura concluida.\n");

  // 2. Teste Visual dos LCDs
  // A função begin() retorna 0 se deu certo, ou um código de erro se falhou.
  
  // --- TESTE LCD MAIN (0x27) ---
  Serial.print("Iniciando LCD Main (0x27)... ");
  int statusMain = lcd_main.begin(16, 2); 

  if(statusMain == 0) {
    Serial.println("SUCESSO.");
    // Nota: O backlight liga automaticamente no begin()
    lcd_main.setCursor(0,0);
    lcd_main.print("TESTE HARDWARE");
    lcd_main.setCursor(0,1);
    lcd_main.print("ADDR: 0x27 (MAIN)");
  } else {
    Serial.print("FALHA! Codigo erro: ");
    Serial.println(statusMain);
  }

  // --- TESTE LCD SEC (0x28) ---
  Serial.print("Iniciando LCD Sec (0x28)... ");
  int statusSec = lcd_sec.begin(16, 2);

  if(statusSec == 0) {
    Serial.println("SUCESSO.");
    lcd_sec.setCursor(0,0);
    lcd_sec.print("TESTE HARDWARE");
    lcd_sec.setCursor(0,1);
    lcd_sec.print("ADDR: 0x28 (SEC)");
  } else {
    Serial.print("FALHA! Codigo erro: ");
    Serial.println(statusSec);
  }
}

void loop() {
  // Pisca o LED da placa (se houver) ou apenas delay para manter ativo
  delay(1000);
}