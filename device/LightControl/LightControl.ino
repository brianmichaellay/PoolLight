#include <WiFi.h>
#include <ESPmDNS.h>
#include <Preferences.h>

// Pool light: Pentair® Intellibrite® 5G Color Splash XG Series
// This firmware provides Wi-Fi setup, relay power control, and color effect selection.
const char* AP_SSID = "LIGHT_SETUP";
const char* AP_PASSWORD = ""; // open AP for setup
const char* HOSTNAME = "poollight";
const char* LOCAL_HOSTNAME = "poollight.local";

const int relayPin = 4;
const int buttonPin = 5;
const int ledPin = 13;
const bool relayActiveLow = true; // Relay is active-low: LOW = ON, HIGH = OFF

Preferences prefs;
WiFiServer server(80);

bool hasConfig = false;
String savedSSID;
String savedPassword;
int wifiAttempts = 0;
unsigned long nextWiFiAttempt = 0;

int pulseDelayMs = 250;

unsigned long buttonDownMillis = 0;
unsigned long lastLedToggle = 0;
bool ledOn = false;

enum DeviceMode {
  MODE_SETUP,
  MODE_STA,
};

DeviceMode deviceMode = MODE_SETUP;

void setRelayState(bool on) {
  int level = on ? (relayActiveLow ? LOW : HIGH) : (relayActiveLow ? HIGH : LOW);
  digitalWrite(relayPin, level);
}

bool isRelayOn() {
  return digitalRead(relayPin) == (relayActiveLow ? LOW : HIGH);
}

void setup() {
  pinMode(relayPin, OUTPUT);
  setRelayState(false);
  pinMode(buttonPin, INPUT_PULLUP);
  pinMode(ledPin, OUTPUT);
  digitalWrite(ledPin, LOW);

  Serial.begin(115200);
  delay(100);

  prefs.begin("light", false);
  hasConfig = prefs.getBool("configured", false);
  pulseDelayMs = prefs.getInt("pulseDelay", 250);
  if (hasConfig) {
    savedSSID = prefs.getString("ssid", "");
    savedPassword = prefs.getString("pass", "");
  }

  if (hasConfig && savedSSID.length() > 0) {
    startStaMode();
  } else {
    startSetupMode();
  }
}

void loop() {
  handleButton();

  if (deviceMode == MODE_SETUP) {
    handleSetupClients();
    updateLedFlash();
  } else if (deviceMode == MODE_STA) {
    if (WiFi.status() != WL_CONNECTED) {
      attemptWiFiConnect();
    } else {
      digitalWrite(ledPin, HIGH);
      handleStaClients();
    }
  }
}

void startSetupMode() {
  Serial.println("Starting setup mode: broadcasting LIGHT_SETUP");
  WiFi.disconnect(true, true);
  delay(100);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID);
  delay(100);
  // Ensure relay is off while in setup mode to avoid accidental toggles
  setRelayState(false);
  IPAddress ip = WiFi.softAPIP();
  Serial.printf("Setup page available at http://%u.%u.%u.%u/\n", ip[0], ip[1], ip[2], ip[3]);
  server.begin();
  deviceMode = MODE_SETUP;
  wifiAttempts = 0;
}

void startStaMode() {
  Serial.println("Starting STA mode");
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(HOSTNAME);
  Serial.printf("Set Wi-Fi hostname to %s for router registration\n", HOSTNAME);
  // If already connected, ensure the Wi-Fi LED shows solid
  if (WiFi.status() == WL_CONNECTED) {
    digitalWrite(ledPin, HIGH);
  } else {
    digitalWrite(ledPin, LOW);
  }
  // Ensure the HTTP server is listening as soon as we enter STA mode
  server.begin();
  deviceMode = MODE_STA;
}

void attemptWiFiConnect() {
  // If we've scheduled the next attempt in the future, skip for now
  if (millis() < nextWiFiAttempt) {
    return;
  }

  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  Serial.printf("Connecting to SSID '%s' attempt %d\n", savedSSID.c_str(), wifiAttempts + 1);
  WiFi.begin(savedSSID.c_str(), savedPassword.c_str());

  unsigned long start = millis();
  while (millis() - start < 5000) {
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("Connected to Wi-Fi");
      IPAddress ip = WiFi.localIP();
      Serial.printf("Device IP address: http://%u.%u.%u.%u/\n", ip[0], ip[1], ip[2], ip[3]);
      // Show solid Wi-Fi LED when connected
      digitalWrite(ledPin, HIGH);
      WiFi.setHostname(HOSTNAME);
      Serial.printf("Set Wi-Fi hostname to %s for router registration\n", HOSTNAME);
      if (MDNS.begin(HOSTNAME)) {
        Serial.printf("mDNS responder started for %s\n", LOCAL_HOSTNAME);
      } else {
        Serial.println("mDNS responder failed to start");
      }
      server.begin();
      wifiAttempts = 0;
      nextWiFiAttempt = 0;
      return;
    }
    delay(100);
  }

  // Failed this attempt: increment counter for logging and schedule next attempt
  wifiAttempts++;
  Serial.printf("Connect failed, count=%d — will retry in 20s\n", wifiAttempts);
  nextWiFiAttempt = millis() + 20000UL; // schedule next try in 20 seconds (non-blocking)
}

void handleSetupClients() {
  WiFiClient client = server.available();
  if (!client) {
    return;
  }

  Serial.println("Client connected to setup server");
  String request = readHttpRequest(client);
  Serial.println(request);

  if (request.startsWith("POST /config")) {
    String body = getHttpBody(request);
    String ssid = getValue(body, "ssid");
    String pass = getValue(body, "pass");

    if (ssid.length() > 0) {
      saveConfig(ssid, pass);
      sendHttpResponse(client, 200, "text/plain", "Configuration saved. Rebooting...");
      delay(1000);
      ESP.restart();
      return;
    }

    sendHttpResponse(client, 400, "text/plain", "Missing ssid or pass");
  } else if (request.startsWith("GET /identity")) {
    sendHttpResponse(client, 200, "text/plain", "poollight-setup");
  } else if (request.startsWith("GET /")) {
    String page = buildSetupPage();
    sendHttpResponse(client, 200, "text/html", page);
  } else {
    sendHttpResponse(client, 404, "text/plain", "Not found");
  }
}

void handleStaClients() {
  WiFiClient client = server.available();
  if (!client) {
    return;
  }

  Serial.println("Client connected to STA server");
  String request = readHttpRequest(client);
  Serial.println(request);

  if (request.startsWith("GET /color/")) {
    String path = getRequestPath(request);
    String value = "";
    if (path.startsWith("/color/")) {
      value = path.substring(String("/color/").length());
    }
    Serial.printf("Color request received: '%s' (path='%s')\n", value.c_str(), path.c_str());
    if (value.length() > 0) {
      applyColor(value);
      sendHttpResponse(client, 200, "text/plain", "Color command received");
    } else {
      sendHttpResponse(client, 400, "text/plain", "Missing color");
    }
  } else if (request.startsWith("GET /power/")) {
    String path = getRequestPath(request);
    String value = "";
    if (path.startsWith("/power/")) {
      value = path.substring(String("/power/").length());
    }
    Serial.printf("Power request received: '%s' (path='%s')\n", value.c_str(), path.c_str());
    if (value.equalsIgnoreCase("on")) {
      setRelayState(true);
      sendHttpResponse(client, 200, "text/plain", "Power ON");
    } else {
      setRelayState(false);
      sendHttpResponse(client, 200, "text/plain", "Power OFF");
    }
  } else if (request.startsWith("GET /lock")) {
    toggleRelay(13);
    sendHttpResponse(client, 200, "text/plain", "Color locked");
  } else if (request.startsWith("GET /return")) {
    toggleRelay(14);
    sendHttpResponse(client, 200, "text/plain", "Return command sent");
  } else if (request.startsWith("GET /pulse-delay/")) {
    String path = getRequestPath(request);
    String value = "";
    if (path.startsWith("/pulse-delay/")) {
      value = path.substring(String("/pulse-delay/").length());
    }
    int newDelay = value.toInt();
    if (newDelay >= 1) {
      pulseDelayMs = newDelay;
      prefs.putInt("pulseDelay", pulseDelayMs);
      Serial.printf("Pulse delay updated: %d ms\n", pulseDelayMs);
      sendHttpResponse(client, 200, "text/plain", "Pulse delay updated");
    } else {
      sendHttpResponse(client, 400, "text/plain", "Invalid pulse delay");
    }
  } else if (request.startsWith("POST /reset")) {
    prefs.clear();
    hasConfig = false;
    savedSSID = "";
    savedPassword = "";
    sendHttpResponse(client, 200, "text/plain", "Wi-Fi reset. Rebooting...");
    delay(1000);
    ESP.restart();
  } else if (request.startsWith("GET /debug")) {
    // Echo the full raw request for debugging client issues
    sendHttpResponse(client, 200, "text/plain", request);
  } else if (request.startsWith("GET /identity")) {
    sendHttpResponse(client, 200, "text/plain", "poollight");
  } else if (request.startsWith("GET /")) {
    String page = buildStaPage();
    sendHttpResponse(client, 200, "text/html", page);
  } else {
    sendHttpResponse(client, 404, "text/plain", "Not found");
  }
}

String readHttpRequest(WiFiClient& client) {
  String request = "";
  unsigned long timeout = millis() + 2000;
  while (client.connected() && millis() < timeout) {
    if (client.available()) {
      String line = client.readStringUntil('\n');
      request += line + '\n';
      if (line == "\r") {
        break;
      }
    }
  }

  int contentLength = 0;
  int index = request.indexOf("Content-Length:");
  if (index >= 0) {
    String lengthLine = request.substring(index);
    int endOfLine = lengthLine.indexOf('\n');
    lengthLine = lengthLine.substring(0, endOfLine);
    contentLength = lengthLine.substring(String("Content-Length:").length()).toInt();
  }

  if (contentLength > 0) {
    String body = "";
    unsigned long bodyTimeout = millis() + 5000;
    while ((int)body.length() < contentLength && client.connected() && millis() < bodyTimeout) {
      if (client.available()) {
        body += (char)client.read();
      } else {
        delay(10);
      }
    }
    request += body;
  }

  return request;
}

String getHttpBody(const String& request) {
  int bodyIndex = request.indexOf("\r\n\r\n");
  if (bodyIndex >= 0) {
    return request.substring(bodyIndex + 4);
  }
  return "";
}

String getRequestPath(const String& request) {
  int lineEnd = request.indexOf("\r\n");
  if (lineEnd < 0) {
    lineEnd = request.indexOf('\n');
  }
  if (lineEnd < 0) {
    return "";
  }
  String firstLine = request.substring(0, lineEnd);
  int firstSpace = firstLine.indexOf(' ');
  if (firstSpace < 0) {
    return "";
  }
  int secondSpace = firstLine.indexOf(' ', firstSpace + 1);
  if (secondSpace < 0) {
    return "";
  }
  return firstLine.substring(firstSpace + 1, secondSpace);
}

String getValue(const String& data, const String& key) {
  String search = key + "=";
  int start = data.indexOf(search);
  if (start < 0) {
    return "";
  }
  start += search.length();
  int end = data.indexOf('&', start);
  if (end < 0) {
    end = data.length();
  }
  String value = data.substring(start, end);
  value.replace('+', ' ');
  return urlDecode(value);
}

String urlDecode(const String& input) {
  String decoded = "";
  for (unsigned int i = 0; i < input.length(); i++) {
    char c = input[i];
    if (c == '+') {
      decoded += ' ';
    } else if (c == '%' && i + 2 < input.length()) {
      String hex = input.substring(i + 1, i + 3);
      decoded += (char) strtol(hex.c_str(), NULL, 16);
      i += 2;
    } else {
      decoded += c;
    }
  }
  return decoded;
}

void sendHttpResponse(WiFiClient& client, int code, const String& message) {
  sendHttpResponse(client, code, "text/plain", message);
}

void sendHttpResponse(WiFiClient& client, int code, const String& contentType, const String& body) {
  client.printf("HTTP/1.1 %d OK\r\n", code);
  client.print("Content-Type: ");
  client.print(contentType);
  client.print("\r\nConnection: close\r\n");
  client.printf("Content-Length: %d\r\n\r\n", body.length());
  client.print(body);
  client.stop();
}

String buildSetupPage() {
  String html = "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>Light Setup</title>";
  html += "<style>body{font-family:Arial,sans-serif;padding:20px;font-size:18px;}label{display:block;margin-top:12px;}";
  html += "select,input{width:30ch;max-width:100%;padding:8px;margin-top:4px;display:inline-block;font-size:16px;}button{margin-top:16px;padding:10px 18px;}";
  html += "</style></head><body><h1>Light Setup</h1><p>Select your Wi-Fi network and enter the password.</p>";
  html += "<form method=\"POST\" action=\"/config\">";
  html += "<label for=\"ssid\">Wi-Fi SSID</label><select id=\"ssid\" name=\"ssid\">";

  int networks = WiFi.scanNetworks();
  if (networks <= 0) {
    html += "<option value=\"\">No networks found</option>";
  } else {
    for (int i = 0; i < networks; i++) {
      String ssid = WiFi.SSID(i);
      int32_t rssi = WiFi.RSSI(i);
      html += "<option value=\"" + ssid + "\">" + ssid + " (" + String(rssi) + " dBm)</option>";
    }
  }

  html += "</select>";
  html += "<label for=\"pass\">Password</label><input id=\"pass\" name=\"pass\" type=\"password\" autocomplete=\"new-password\" placeholder=\"Wi-Fi password\">";
  html += "<button type=\"submit\">Save Wi-Fi</button></form>";
  html += "<p>If your network does not appear, refresh the page.</p></body></html>";
  return html;
}

String buildStaPage() {
  String deviceIp = WiFi.localIP().toString();
  String html = "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>Light Control</title>";
  html += "<style>body{font-family:Arial,sans-serif;padding:20px;font-size:18px;}label{display:block;margin-top:12px;}fieldset{margin-top:12px;padding:12px;border:1px solid #ccc;}button{margin-top:16px;padding:10px 18px;}input[type=radio]{margin:0;padding:0;}select,input{width:30ch;max-width:100%;padding:8px;margin-top:4px;display:inline-block;font-size:16px;}";
  html += ".switch{position:relative;display:inline-block;width:60px;height:34px;}";
  html += ".switch input{opacity:0;width:0;height:0;}";
  html += ".sliderToggle{position:absolute;cursor:pointer;top:0;left:0;right:0;bottom:0;background-color:#ccc;transition:.4s;border-radius:34px;}";
  html += ".sliderToggle:before{position:absolute;content:'';height:26px;width:26px;left:4px;bottom:4px;background:white;transition:.4s;border-radius:50%;}";
  html += "input:checked + .sliderToggle{background-color:#2196F3;}";
  html += "input:checked + .sliderToggle:before{transform:translateX(26px);}";
  html += "#colorField{display:block;padding:0;margin:0;}";
  html += "#colorField label{display:grid;grid-template-columns:5% 20% 75%;align-items:center;justify-items:start;gap:8px;width:100%;margin-bottom:8px;border:1px solid #ccc;cursor:pointer;box-sizing:border-box;white-space:normal;}";
  html += "#colorField label.selected{border-color:red;background-color:#ffe6e6;}";
  html += "#colorField label > *{padding:0;margin:0;}";
  html += "#colorField label .colorLabelText{display:inline-flex;align-items:center;gap:6px;box-sizing:border-box;}";
  html += "#colorField label .colorNumber{font-weight:700;flex:none;width:2.2ch;}";
  html += "#colorField label .colorName{font-weight:600;display:inline;white-space:normal;}";
  html += "#colorField label .colorDesc{display:block;color:#555;font-size:0.9em;line-height:1.3;margin:0;font-style:italic;}";
  html += "</style>";
  html += "</head><body><h1>Light Control</h1>";
  html += "<p>Device IP: " + deviceIp + "</p>";
  // Power control (slider)
  bool powerOn = isRelayOn();
  html += "<div style=\"display:flex;align-items:center;gap:12px;\">";
  html += "<label for=\"power\">Power</label>";
  html += "<label class=\"switch\"><input id=\"power\" type=\"checkbox\" " + String(powerOn ? "checked" : "") + " /><span class=\"sliderToggle\"></span></label>";
  html += "<span id=\"powerStatus\" style=\"display:inline-flex;align-items:center;gap:6px;\"><span id=\"powerDot\" style=\"width:12px;height:12px;border-radius:50%;background-color:" + String(powerOn ? "green" : "red") + ";\"></span><span id=\"powerText\">" + String(powerOn ? "ON" : "OFF") + "</span></span>";
  html += "</div>";
  html += "<div id=\"statusText\" style=\"margin-top:10px;font-size:16px;color:#333;\"></div>";

  // Color control (disabled when power is off)
  html += "<form id=\"colorForm\" method=\"POST\" action=\"/color\">";
  html += "<fieldset id=\"colorField\"><legend>Choose a color</legend>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"1\" checked" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">1.</span><span class=\"colorName\">Peruvian Paradise</span></span><span class=\"colorDesc\">Cycles through white, magenta, blue and green colors.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"2\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">2.</span><span class=\"colorName\">Super Nova</span></span><span class=\"colorDesc\">Rapid color changing building energy and excitement.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"3\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">3.</span><span class=\"colorName\">Northern Lights</span></span><span class=\"colorDesc\">Slow transitions creating a mesmerizing and calming effect.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"4\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">4.</span><span class=\"colorName\">Tidal Wave</span></span><span class=\"colorDesc\">Transitions between a variety of blues and greens.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"5\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">5.</span><span class=\"colorName\">Patriot Dream</span></span><span class=\"colorDesc\">Patriotic red, white and blue transitions.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"6\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">6.</span><span class=\"colorName\">Desert Skies</span></span><span class=\"colorDesc\">Dramatic transitions of orange, red and magenta tones.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"7\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">7.</span><span class=\"colorName\">Nova</span></span><span class=\"colorDesc\">Richer, deeper color tones.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"8\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">8.</span><span class=\"colorName\">Parisian Blue</span></span><span class=\"colorDesc\">Fixed deep blue color.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"9\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">9.</span><span class=\"colorName\">New Zealand Green</span></span><span class=\"colorDesc\">Fixed rich green color.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"10\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">10.</span><span class=\"colorName\">Brazilian Red</span></span><span class=\"colorDesc\">Fixed vibrant red color.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"11\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">11.</span><span class=\"colorName\">Arctic White</span></span><span class=\"colorDesc\">Fixed bright white color.</span></label>";
  html += "<label><input type=\"radio\" name=\"color\" value=\"12\"" + String(powerOn ? "" : " disabled") + "><span class=\"colorLabelText\"><span class=\"colorNumber\">12.</span><span class=\"colorName\">Miami Pink</span></span><span class=\"colorDesc\">Fixed magenta color.</span></label>";
  html += "</fieldset><div style=\"display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:8px;\">";
  html += "<button id=\"colorBtn\" type=\"submit\"" + String(powerOn ? "" : " disabled") + ">Set Color</button>";
  html += "<button id=\"colorLockBtn\" type=\"button\"" + String(powerOn ? "" : " disabled") + ">Color Lock</button>";
  html += "<button id=\"returnBtn\" type=\"button\">Return</button>";
  html += "</div></form>";
  html += "<details id=\"advancedSettings\" style=\"margin-top:16px;border:1px solid #ccc;padding:10px;border-radius:8px;\">";
  html += "<summary style=\"font-size:1.05em;cursor:pointer;\">Advanced Settings</summary>";
  html += "<div style=\"margin-top:12px;display:grid;gap:12px;\">";
  html += "<div style=\"display:flex;align-items:center;gap:8px;\">";
  html += "<label for=\"pulseDelay\" style=\"min-width:10ch;\">Pulse delay (ms)</label>";
  html += "<input id=\"pulseDelay\" type=\"number\" min=\"1\" value=\"" + String(pulseDelayMs) + "\" style=\"width:8ch;padding:4px;\">";
  html += "<button id=\"pulseDelayBtn\" type=\"button\">Save delay</button>";
  html += "</div>";
  html += "<div id=\"advancedStatusText\" style=\"font-size:0.95em;color:#333;\"></div>";
  html += "<form method=\"POST\" action=\"/reset\" style=\"margin:0;\">";
  html += "<button type=\"submit\">Reset Wi-Fi Configuration</button>";
  html += "</form>";
  html += "</div></details>";

  // JS to handle power toggle and enable/disable color controls
  html += "<script>";
  html += "const power = document.getElementById('power');";
  html += "const colorForm = document.getElementById('colorForm');";
  html += "const colorField = document.getElementById('colorField');";
  html += "const colorBtn = document.getElementById('colorBtn');";
  html += "const colorLockBtn = document.getElementById('colorLockBtn');";
  html += "const returnBtn = document.getElementById('returnBtn');";
  html += "const powerDot = document.getElementById('powerDot');";
  html += "const powerText = document.getElementById('powerText');";
  html += "const statusText = document.getElementById('statusText');";
  html += "const pulseDelayInput = document.getElementById('pulseDelay');";
  html += "const pulseDelayBtn = document.getElementById('pulseDelayBtn');";
  html += "const advancedStatusText = document.getElementById('advancedStatusText');";
  html += "let powerRequestInFlight = false;";
  html += "function getColorInputs(){ return Array.from(colorField.querySelectorAll(\"input[name=\\\"color\\\"]\")); }";
  html += "function setPowerIndicator(on){";
  html += "  powerDot.style.backgroundColor = on ? 'green' : 'red';";
  html += "  powerText.textContent = on ? 'ON' : 'OFF';";
  html += "}";
  html += "function updateColorEnabled(){";
  html += "  const disabled = !power.checked;";
  html += "  getColorInputs().forEach(i=>i.disabled=disabled);";
  html += "  colorBtn.disabled = disabled;";
  html += "  colorLockBtn.disabled = disabled || !isLockableColor();";
  html += "  if (!disabled) statusText.textContent = '';";
  html += "}";
  html += "function isLockableColor(){";
  html += "  const selected = getColorInputs().find(i => i.checked);";
  html += "  if (!selected) return false;";
  html += "  const value = Number(selected.value);";
  html += "  return value >= 1 && value <= 7;";
  html += "}";
  html += "function updateLockButton(){";
  html += "  colorLockBtn.disabled = !isLockableColor() || !power.checked;";
  html += "}";
  html += "function updateSelectedColor(){";
  html += "  getColorInputs().forEach(input => {";
  html += "    const label = input.parentElement;";
  html += "    if (input.checked) label.classList.add('selected'); else label.classList.remove('selected');";
  html += "  });";
  html += "}";
  html += "async function togglePower(){";
  html += "  if (powerRequestInFlight) return;";
  html += "  const value = power.checked ? 'on' : 'off';";
  html += "  powerRequestInFlight = true;";
  html += "  power.disabled = true;";
  html += "  statusText.textContent = 'Updating power...';";
  html += "  try {";
  html += "    const resp = await fetch('/power/' + value, {method:'GET', cache:'no-store'});";
  html += "    if (!resp.ok) throw new Error('HTTP ' + resp.status);";
  html += "    await resp.text();";
  html += "    setPowerIndicator(power.checked);";
  html += "    statusText.textContent = power.checked ? 'Power ON' : 'Power OFF';";
  html += "  } catch (err) {";
  html += "    power.checked = !power.checked;";
  html += "    setPowerIndicator(power.checked);";
  html += "    statusText.textContent = 'Power update failed';";
  html += "  } finally {";
  html += "    power.disabled = false;";
  html += "    updateColorEnabled();";
  html += "    powerRequestInFlight = false;";
  html += "  }";
  html += "}";
  html += "power.addEventListener('change', togglePower);";
  html += "document.addEventListener('DOMContentLoaded', ()=>{ updateColorEnabled(); setPowerIndicator(power.checked); updateSelectedColor(); updateLockButton(); });";
  html += "getColorInputs().forEach(input=>input.addEventListener('change', ()=>{ updateSelectedColor(); updateLockButton(); }));";
  html += "colorForm.addEventListener('submit', async (event)=>{";
  html += "  event.preventDefault();";
  html += "  if (!power.checked) return;";
  html += "  const selected = getColorInputs().find(i => i.checked);";
  html += "  if (!selected) return;";
  html += "  colorBtn.disabled = true;";
  html += "  try {";
  html += "    const resp = await fetch('/color/' + encodeURIComponent(selected.value), {method:'GET', cache:'no-store'});";
  html += "    if (!resp.ok) throw new Error('HTTP ' + resp.status);";
  html += "    await resp.text();";
  html += "    updateSelectedColor();";
  html += "    updateLockButton();";
  html += "  } catch (err) {";
  html += "    alert('Color update failed');";
  html += "  } finally {";
  html += "    colorBtn.disabled = false;";
  html += "  }";
  html += "});";
  html += "colorLockBtn.addEventListener('click', async ()=>{";
  html += "  if (colorLockBtn.disabled) return;";
  html += "  colorLockBtn.disabled = true;";
  html += "  statusText.textContent = 'Locking color...';";
  html += "  try {";
  html += "    const resp = await fetch('/lock', {method:'GET', cache:'no-store'});";
  html += "    if (!resp.ok) throw new Error('HTTP ' + resp.status);";
  html += "    await resp.text();";
  html += "    statusText.textContent = 'Color locked.';";
  html += "  } catch (err) {";
  html += "    statusText.textContent = 'Color lock failed';";
  html += "  } finally {";
  html += "    updateColorEnabled();";
  html += "    colorLockBtn.disabled = !isLockableColor() || !power.checked;";
  html += "  }";
  html += "});";
  html += "returnBtn.addEventListener('click', async ()=>{";
  html += "  if (returnBtn.disabled) return;";
  html += "  returnBtn.disabled = true;";
  html += "  statusText.textContent = 'Returning color...';";
  html += "  try {";
  html += "    const resp = await fetch('/return', {method:'GET', cache:'no-store'});";
  html += "    if (!resp.ok) throw new Error('HTTP ' + resp.status);";
  html += "    await resp.text();";
  html += "    statusText.textContent = 'Return command sent.';";
  html += "  } catch (err) {";
  html += "    statusText.textContent = 'Return failed';";
  html += "  } finally {";
  html += "    returnBtn.disabled = false;";
  html += "  }";
  html += "});";
  html += "pulseDelayBtn.addEventListener('click', async ()=>{";
  html += "  const value = pulseDelayInput.value.trim();";
  html += "  if (!value || isNaN(value) || Number(value) < 1) { advancedStatusText.textContent = 'Enter a valid delay'; return; }";
  html += "  pulseDelayBtn.disabled = true;";
  html += "  advancedStatusText.textContent = 'Saving pulse delay...';";
  html += "  try {";
  html += "    const resp = await fetch('/pulse-delay/' + encodeURIComponent(value), {method:'GET', cache:'no-store'});";
  html += "    if (!resp.ok) throw new Error('HTTP ' + resp.status);";
  html += "    await resp.text();";
  html += "    advancedStatusText.textContent = 'Pulse delay saved.';";
  html += "  } catch (err) {";
  html += "    advancedStatusText.textContent = 'Failed to save pulse delay';";
  html += "  } finally {";
  html += "    pulseDelayBtn.disabled = false;";
  html += "  }";
  html += "});";
  html += "</script>";
  html += "</body></html>";
  return html;
}

void saveConfig(const String& ssid, const String& pass) {
  Serial.println("Saving Wi-Fi configuration to flash");
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.putBool("configured", true);
  savedSSID = ssid;
  savedPassword = pass;
}

void applyColor(const String& color) {
  Serial.printf("Applying color: %s\n", color.c_str());
  int toggleCount = color.toInt();

  if (toggleCount < 1 || toggleCount > 12) {
    if (color.equalsIgnoreCase("red")) {
      toggleCount = 2;
    } else if (color.equalsIgnoreCase("green")) {
      toggleCount = 4;
    } else if (color.equalsIgnoreCase("blue")) {
      toggleCount = 6;
    } else if (color.equalsIgnoreCase("white")) {
      toggleCount = 1;
    } else {
      toggleCount = 3;
    }
  }

  toggleRelay(toggleCount);
}

void toggleRelay(int count) {
  // Pulse the relay 'count' times while preserving its original steady state
  bool orig = isRelayOn();
  bool pulse = !orig;
  for (int i = 0; i < count; i++) {
    setRelayState(pulse);
    delay(pulseDelayMs);
    setRelayState(orig);
    delay(pulseDelayMs);
  }
}

void handleButton() {
  bool pressed = digitalRead(buttonPin) == LOW;
  if (pressed) {
    if (buttonDownMillis == 0) {
      buttonDownMillis = millis();
    } else if (millis() - buttonDownMillis >= 10000) {
      resetToSetupMode();
    }
  } else {
    buttonDownMillis = 0;
  }
}

void resetToSetupMode() {
  Serial.println("Button held 10s: resetting to setup mode");
  prefs.clear();
  hasConfig = false;
  savedSSID = "";
  savedPassword = "";
  startSetupMode();
}

void indicateHostnameRegistration() {
  for (int i = 0; i < 5; i++) {
    digitalWrite(ledPin, LOW);
    delay(50);
    digitalWrite(ledPin, HIGH);
    delay(50);
  }
}

void updateLedFlash() {
  unsigned long now = millis();
  if (now - lastLedToggle >= 500) {
    ledOn = !ledOn;
    digitalWrite(ledPin, ledOn ? HIGH : LOW);
    lastLedToggle = now;
  }
}
