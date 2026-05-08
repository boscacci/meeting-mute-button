local repoRoot = "/Users/rob/repos/mute-button"
local logPath = repoRoot .. "/hammerspoon-debug.log"
local debugHeartbeats = false
local serialPortPath = "/dev/cu.usbserial-0001"
local serialBaudRate = 115200
local teamsActivationDelaySeconds = 0.15
local maxAccessibilitySearchDepth = 24
local teamsBundleIds = {
  "com.microsoft.teams2",
  "com.microsoft.teams",
}

local serialPort = nil
local serialBuffer = ""
local lastToggleAt = 0
local serialReconnectGeneration = 0
local muteStates = {
  muted = { name = "muted", ledColor = "red", alert = "Mic is muted" },
  unmuted = { name = "unmuted", ledColor = "green", alert = "Mic is hot!" },
}
local accessibilityTextAttributes = {
  "AXRole",
  "AXTitle",
  "AXDescription",
  "AXHelp",
  "AXValue",
  "AXIdentifier",
}
local buttonRoles = {
  AXButton = true,
  AXCheckBox = true,
  AXToggle = true,
}
local micTextPatterns = {
  "mute",
  "unmute",
  "microphone",
  "%f[%a]mic%f[%A]",
}

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

local function stateFor(muteState)
  return muteStates[muteState] or { name = tostring(muteState), ledColor = "unknown", alert = "Teams mute toggled" }
end

local function alertForMuteState(muteState)
  return stateFor(muteState).alert
end

local function alertForUnavailableTeamsMicControl(muteState)
  local state = stateFor(muteState)
  return state.alert .. " (LED " .. state.ledColor .. "). No call mic button found."
end

local function isTeamsFrontmost(teams)
  local frontmostApp = hs.application.frontmostApplication()
  return frontmostApp and frontmostApp:bundleID() == teams:bundleID()
end

local function attributeValue(element, attribute)
  local ok, value = pcall(function()
    return element:attributeValue(attribute)
  end)
  if ok then
    return value
  end
  return nil
end

local function typedAttribute(element, attribute, expectedType)
  local value = attributeValue(element, attribute)
  if type(value) == expectedType then
    return value
  end
  return nil
end

local function stringAttribute(element, attribute)
  return typedAttribute(element, attribute, "string") or ""
end

local function tableAttribute(element, attribute)
  return typedAttribute(element, attribute, "table")
end

local function elementText(element)
  local parts = {}
  for _, attribute in ipairs(accessibilityTextAttributes) do
    table.insert(parts, stringAttribute(element, attribute))
  end
  return table.concat(parts, " ")
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

local function teamsMicStateFromButtonText(text)
  local lower = text:lower()
  if lower:match("unmute") then
    return "muted"
  elseif lower:match("%f[%a]mute%f[%A]") then
    return "unmuted"
  end
  return nil
end

local function clickElementCenter(element)
  local position = tableAttribute(element, "AXPosition")
  local size = tableAttribute(element, "AXSize")
  if not position or not size then
    log("Could not read Teams mic button geometry for mouse click")
    return false
  end

  local previousMousePosition = hs.mouse.absolutePosition()
  local clickPoint = {
    x = position.x + (size.w / 2),
    y = position.y + (size.h / 2),
  }
  hs.eventtap.leftClick(clickPoint)
  hs.mouse.absolutePosition(previousMousePosition)
  return true
end

local function findMicButton(element, depth, seen)
  if not element or depth > maxAccessibilitySearchDepth then
    return nil
  end

  local elementId = tostring(element)
  if seen[elementId] then
    return nil
  end
  seen[elementId] = true

  local role = stringAttribute(element, "AXRole")
  local text = elementText(element):lower()
  local mentionsMic = false
  for _, pattern in ipairs(micTextPatterns) do
    if text:match(pattern) then
      mentionsMic = true
      break
    end
  end

  if buttonRoles[role] and canPress(element) and mentionsMic then
    return element, text
  end

  local children = tableAttribute(element, "AXChildren")
  if not children then
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

local function handleTeamsMicState(teams, targetMuteState)
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

  local currentTeamsMicState = teamsMicStateFromButtonText(text)
  if muteStates[targetMuteState] and currentTeamsMicState == targetMuteState then
    log("Teams mic already matches LED state; no click needed; state=" .. targetMuteState .. " text=" .. text)
    return true
  end

  if muteStates[targetMuteState] and not currentTeamsMicState then
    log("Teams mic button found, but state could not be inferred; text=" .. text)
    return false
  end

  log("Mouse-clicking Teams mic button: " .. text .. " target state=" .. tostring(targetMuteState) .. " current state=" .. tostring(currentTeamsMicState))
  local clicked = clickElementCenter(button)
  log("Teams mic mouse click result=" .. tostring(clicked))
  return clicked
end

local function handleTeamsWhenFrontmost(teams, muteState, attempt)
  attempt = attempt or 1

  if isTeamsFrontmost(teams) then
    if handleTeamsMicState(teams, muteState) then
      log("Teams mic state handled through accessibility")
    else
      log("Teams is frontmost; no safe mic action available; target state=" .. tostring(muteState))
      hs.alert.show(alertForUnavailableTeamsMicControl(muteState))
      return
    end
    hs.alert.show(alertForMuteState(muteState))
    return
  end

  if attempt >= 20 then
    log("Teams did not become frontmost; skipped mic update")
    hs.alert.show("Teams did not focus")
    return
  end

  hs.timer.doAfter(0.05, function()
    handleTeamsWhenFrontmost(teams, muteState, attempt + 1)
  end)
end

local function toggleTeamsMute(muteState)
  if not muteStates[muteState] then
    log("Ignored unknown mute state: " .. tostring(muteState))
    return
  end

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

  log("Activating Teams before mic update; target state=" .. tostring(muteState))
  teams:activate(true)
  hs.timer.doAfter(teamsActivationDelaySeconds, function()
    handleTeamsWhenFrontmost(teams, muteState)
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

scheduleSerialOpen(1)
hs.alert.show("Mute button config loaded")
log("Mute button config loaded")
