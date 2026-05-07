local repoRoot = "/Users/rob/repos/mute-button"
local logPath = repoRoot .. "/hammerspoon-debug.log"
local debugHeartbeats = false
local serialPortPath = "/dev/cu.usbserial-0001"
local serialBaudRate = 115200
local teamsActivationDelaySeconds = 0.15
local useAccessibilityMicButton = true
local sendKeyboardShortcut = false
local teamsBundleIds = {
  "com.microsoft.teams2",
  "com.microsoft.teams",
}

local serialPort = nil
local serialBuffer = ""
local lastToggleAt = 0
local serialReconnectGeneration = 0

local function log(message)
  local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(message)
  local file = io.open(logPath, "a")
  if file then
    file:write(line .. "\n")
    file:close()
  end
  print(line)
end

if hs.ipc then
  hs.ipc.cliInstall()
  log("IPC CLI installed")
end

local function findTeams()
  for _, bundleId in ipairs(teamsBundleIds) do
    local app = hs.application.get(bundleId)
    if app then
      log("Found Teams app bundle=" .. bundleId .. " name=" .. tostring(app:name()))
      return app
    end
  end
  log("Teams app not found")
  return nil
end

local function alertForMuteState(muteState)
  if muteState == "muted" then
    return "Mic is muted"
  elseif muteState == "unmuted" then
    return "Mic is hot!"
  end
  return "Teams mute toggled"
end

local function alertForUnavailableTeamsMicControl(muteState)
  if muteState == "muted" then
    return "Mic is muted (LED red). No call mic button found."
  elseif muteState == "unmuted" then
    return "Mic is hot! (LED green). No call mic button found."
  end
  return "LED changed. No call mic button found."
end

local function isTeamsFrontmost(teams)
  local frontmostApp = hs.application.frontmostApplication()
  return frontmostApp and frontmostApp:bundleID() == teams:bundleID()
end

local function stringAttribute(element, attribute)
  local ok, value = pcall(function()
    return element:attributeValue(attribute)
  end)
  if ok and type(value) == "string" then
    return value
  end
  return ""
end

local function elementText(element)
  return table.concat({
    stringAttribute(element, "AXRole"),
    stringAttribute(element, "AXTitle"),
    stringAttribute(element, "AXDescription"),
    stringAttribute(element, "AXHelp"),
    stringAttribute(element, "AXValue"),
  }, " ")
end

local function canPress(element)
  local ok, actions = pcall(function()
    return element:actionNames()
  end)
  if not ok or type(actions) ~= "table" then
    return false
  end
  for _, action in ipairs(actions) do
    if action == "AXPress" then
      return true
    end
  end
  return false
end

local function findMicButton(element, depth, seen)
  if not element or depth > 14 then
    return nil
  end

  local elementId = tostring(element)
  if seen[elementId] then
    return nil
  end
  seen[elementId] = true

  local role = stringAttribute(element, "AXRole")
  local text = elementText(element):lower()
  local isButtonLike = role == "AXButton" or role == "AXCheckBox" or role == "AXToggle"
  local mentionsMic = text:match("mute") or text:match("unmute") or text:match("microphone") or text:match("%f[%a]mic%f[%A]")

  if isButtonLike and canPress(element) and mentionsMic then
    return element, text
  end

  local ok, children = pcall(function()
    return element:attributeValue("AXChildren")
  end)
  if not ok or type(children) ~= "table" then
    return nil
  end

  for _, child in ipairs(children) do
    local found, foundText = findMicButton(child, depth + 1, seen)
    if found then
      return found, foundText
    end
  end

  return nil
end

local function clickTeamsMicButton(teams)
  local appElement = hs.axuielement.applicationElement(teams)
  if not appElement then
    log("Could not get Teams accessibility root")
    return false
  end

  local button, text = findMicButton(appElement, 0, {})
  if not button then
    log("No Teams mic/mute accessibility button found")
    return false
  end

  log("Pressing Teams mic/mute accessibility element: " .. text)
  local ok, result = pcall(function()
    return button:performAction("AXPress")
  end)
  log("Teams mic/mute accessibility press ok=" .. tostring(ok) .. " result=" .. tostring(result))
  return ok
end

local function sendMuteShortcutWhenTeamsIsFrontmost(teams, muteState, attempt)
  attempt = attempt or 1

  if isTeamsFrontmost(teams) then
    if useAccessibilityMicButton and clickTeamsMicButton(teams) then
      log("Teams left focused after accessibility mic button press")
    elseif sendKeyboardShortcut then
      log("Teams is frontmost; sending app-targeted mute shortcut; target state=" .. tostring(muteState))
      hs.eventtap.keyStroke({ "cmd", "shift" }, "m", 100000, teams)
      log("Teams left focused after mute shortcut")
    else
      log("Teams is frontmost; no safe mic action available; target state=" .. tostring(muteState))
      hs.alert.show(alertForUnavailableTeamsMicControl(muteState))
      return
    end
    hs.alert.show(alertForMuteState(muteState))
    return
  end

  if attempt >= 20 then
    log("Teams did not become frontmost; skipped mute shortcut")
    hs.alert.show("Teams did not focus")
    return
  end

  hs.timer.doAfter(0.05, function()
    sendMuteShortcutWhenTeamsIsFrontmost(teams, muteState, attempt + 1)
  end)
end

local function toggleTeamsMute(muteState)
  local now = hs.timer.secondsSinceEpoch()
  if now - lastToggleAt < 0.4 then
    log("Ignored duplicate toggle inside debounce window")
    return
  end
  lastToggleAt = now

  local teams = findTeams()
  if not teams then
    hs.alert.show("Teams is not running")
    return
  end

  log("Activating Teams before mute shortcut; target state=" .. tostring(muteState))
  teams:activate(true)
  hs.timer.doAfter(teamsActivationDelaySeconds, function()
    sendMuteShortcutWhenTeamsIsFrontmost(teams, muteState)
  end)
end

_G.toggleTeamsMuteFromArduinoButton = toggleTeamsMute

local function handleSerialLine(line)
  if not debugHeartbeats and line:match("^heartbeat ") then
    return
  end
  log("Serial line: " .. line)
  if line:match("^pressed%-toggle") then
    toggleTeamsMute(line:match("state=(%w+)"))
  end
end

local function handleSerialData(data)
  serialBuffer = serialBuffer .. data
  while true do
    local line, rest = serialBuffer:match("([^\r\n]*)\r?\n(.*)")
    if not line then
      break
    end
    serialBuffer = rest
    handleSerialLine(line)
  end
end

local function closeSerialPort(reason)
  if not serialPort then
    return
  end

  log("Closing serial port: " .. tostring(reason))
  pcall(function()
    serialPort:callback(nil)
  end)
  pcall(function()
    if serialPort:isOpen() then
      serialPort:close()
    end
  end)
  serialPort = nil
  serialBuffer = ""
end

local openSerialPort

local function scheduleSerialOpen(delaySeconds)
  serialReconnectGeneration = serialReconnectGeneration + 1
  local generation = serialReconnectGeneration
  hs.timer.doAfter(delaySeconds, function()
    if generation == serialReconnectGeneration then
      openSerialPort()
    else
      log("Skipped stale serial reconnect generation=" .. tostring(generation))
    end
  end)
end

openSerialPort = function()
  if serialPort and serialPort:isOpen() then
    log("Serial port already open: " .. serialPortPath)
    return
  end

  closeSerialPort("pre-open cleanup")

  log("Opening serial port: " .. serialPortPath)
  serialPort = hs.serial.newFromPath(serialPortPath)
  if not serialPort then
    log("Arduino serial port not found")
    hs.alert.show("Arduino serial port not found")
    return
  end

  serialPort:baudRate(serialBaudRate)
  serialPort:dtr(false)
  serialPort:rts(false)
  serialPort:callback(function(_, callbackType, message)
    if callbackType == "received" then
      handleSerialData(message)
    elseif callbackType == "removed" or callbackType == "closed" then
      log("Serial callback: " .. tostring(callbackType))
      closeSerialPort(callbackType)
      scheduleSerialOpen(1)
      hs.alert.show("Arduino serial disconnected")
    elseif callbackType == "error" then
      log("Serial callback: " .. tostring(callbackType))
      log("Arduino serial error: " .. tostring(message))
      closeSerialPort("error")
      scheduleSerialOpen(1)
      hs.alert.show("Arduino serial error: " .. tostring(message))
    end
  end)

  if serialPort:open() then
    log("Arduino serial connected")
    hs.alert.show("Arduino mute button connected")
  else
    log("Could not open Arduino serial port")
    hs.alert.show("Could not open Arduino serial port")
  end
end

hs.serial.deviceCallback(function()
  log("Serial device list changed")
  closeSerialPort("device list changed")
  scheduleSerialOpen(1)
end)

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "M", toggleTeamsMute)
scheduleSerialOpen(1)
hs.alert.show("Mute button config loaded")
log("Mute button config loaded")
