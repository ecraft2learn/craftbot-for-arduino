/*
 * Author: Göran Krampe
 *
 */

void setup() {
  pinMode(13, OUTPUT);
}

void loop() {
  led_on();
  delay(1000);
  led_off();
  delay(1000);
}

void led_on()
{
  digitalWrite(13, 1);
}

void led_off()
{
  digitalWrite(13, 0);
}