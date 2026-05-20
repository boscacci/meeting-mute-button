local repoRoot = "/Users/rob/repos/mute-button"
local logPath = repoRoot .. "/hammerspoon-debug.log"
local debugHeartbeats = false
local alertDurationSeconds = 0.6
local reconciliationIntervalSeconds = 0.25
local maxReconciliationAttempts = 24
local serialPortPath = "/dev/cu.usbserial-0001"
local serialBaudRate = 115200
local meetingActivationDelaySeconds = 0.15
local maxAccessibilitySearchDepth = 24
local zoomPostPressSettleSeconds = 0.45
local zoomBundleIds = {
  "us.zoom.xos",
}
local teamsBundleIds = {
  "com.microsoft.teams2",
  "com.microsoft.teams",
}

local serialPort = nil
local serialBuffer = ""
local desiredMuteState = nil
local reconciliationGeneration = 0
local serialReconnectGeneration = 0
_G.muteButtonConfigGeneration = (_G.muteButtonConfigGeneration or 0) + 1
local configGeneration = _G.muteButtonConfigGeneration
local zoomLastPressAt = 0
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

local function showAlert(message, seconds)
  hs.alert.closeAll(0)
  hs.alert.show(message, nil, nil, seconds or alertDurationSeconds)
end

if hs.ipc then
  hs.ipc.cliInstall()
  log("IPC CLI installed")
end

local function closeSerialPortObject(port, reason)
  if not port then
    return
  end

  log("Closing serial port: " .. tostring(reason))
  pcall(function()
    port:callback(nil)
  end)
  pcall(function()
    if port:isOpen() then
      port:close()
    end
  end)
end

if _G.muteButtonSerialPort then
  closeSerialPortObject(_G.muteButtonSerialPort, "config reload cleanup")
  _G.muteButtonSerialPort = nil
end

local function findRunningApp(bundleIds, label)
  for _, bundleId in ipairs(bundleIds) do
    local app = hs.application.get(bundleId)
    if app then
      log("Found " .. label .. " app bundle=" .. bundleId .. " name=" .. tostring(app:name()))
      return app
    end
  end
  log(label .. " app not found")
  return nil
end

local function findZoom()
  return findRunningApp(zoomBundleIds, "Zoom")
end

local function findTeams()
  return findRunningApp(teamsBundleIds, "Teams")
end

local function stateFor(muteState)
  return muteStates[muteState] or { name = tostring(muteState), ledColor = "unknown", alert = "Meeting mute toggled" }
end

local function alertForMuteState(muteState)
  return stateFor(muteState).alert
end

local function alertForUnavailableMeetingMicControl(appName, muteState)
  local state = stateFor(muteState)
  return state.alert .. " (LED " .. state.ledColor .. "). No " .. appName .. " call mic button found."
end

local function alertForUnavailableTeamsMicControl(muteState)
  local state = stateFor(muteState)
  return state.alert .. " (LED " .. state.ledColor .. "). No call mic button found."
end

local function alertForUnavailableZoomMicControl(muteState)
  return alertForUnavailableMeetingMicControl("Zoom", muteState)
end

local function isAppFrontmost(app)
  local frontmostApp = hs.application.frontmostApplication()
  return frontmostApp and frontmostApp:bundleID() == app:bundleID()
end

local function isLatestMeetingRequest(requestGeneration)
  if requestGeneration == reconciliationGeneration then
    return true
  end
  log("Skipped stale meeting update generation=" .. tostring(requestGeneration))
  return false
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

local function zoomMicStateFromMenuTitle(title)
  local lower = title:lower()
  if lower:match("^unmute audio") then
    return "muted"
  elseif lower:match("^mute audio") then
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

local function zoomAudioMenuTitle(zoom)
  if zoom:findMenuItem({ "Meeting", "Unmute audio" }) then
    return "Unmute audio"
  elseif zoom:findMenuItem({ "Meeting", "Mute audio" }) then
    return "Mute audio"
  end
  return nil
end

local function handleZoomMicState(zoom, targetMuteState)
  local title = zoomAudioMenuTitle(zoom)
  if not title then
    log("No Zoom mute/unmute audio menu item found")
    return false
  end

  local currentZoomMicState = zoomMicStateFromMenuTitle(title)
  if muteStates[targetMuteState] and currentZoomMicState == targetMuteState then
    log("Zoom audio already matches LED state; no press needed; state=" .. targetMuteState .. " menu item=" .. title)
    return true
  end

  if muteStates[targetMuteState] and not currentZoomMicState then
    log("Zoom audio menu item found, but state could not be inferred; menu item=" .. title)
    return false
  end

  log("Pressing Zoom audio menu item: " .. title .. " target state=" .. tostring(targetMuteState) .. " current state=" .. tostring(currentZoomMicState))
  local ok, selected = pcall(function()
    return zoom:selectMenuItem({ "Meeting", title })
  end)
  local pressed = ok and selected == true
  if pressed then
    zoomLastPressAt = hs.timer.secondsSinceEpoch()
  end
  log("Zoom audio selectMenuItem result=" .. tostring(pressed))
  return pressed
end

local function handleZoomWhenFrontmost(zoom, muteState, requestGeneration, showStatus, attempt)
  attempt = attempt or 1
  if not isLatestMeetingRequest(requestGeneration) then
    return
  end

  if isAppFrontmost(zoom) then
    if handleZoomMicState(zoom, muteState) then
      log("Zoom mic state handled through accessibility")
    else
      log("Zoom is frontmost; no safe mic action available; target state=" .. tostring(muteState))
      if showStatus then
        showAlert(alertForUnavailableZoomMicControl(muteState))
      end
      return
    end
    if showStatus then
      showAlert(alertForMuteState(muteState))
    end
    return
  end

  if attempt >= 20 then
    log("Zoom did not become frontmost; skipped mic update")
    if showStatus then
      showAlert("Zoom did not focus")
    end
    return
  end

  hs.timer.doAfter(0.05, function()
    handleZoomWhenFrontmost(zoom, muteState, requestGeneration, showStatus, attempt + 1)
  end)
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

local function handleTeamsWhenFrontmost(teams, muteState, requestGeneration, showStatus, attempt)
  attempt = attempt or 1
  if not isLatestMeetingRequest(requestGeneration) then
    return
  end

  if isAppFrontmost(teams) then
    if handleTeamsMicState(teams, muteState) then
      log("Teams mic state handled through accessibility")
    else
      log("Teams is frontmost; no safe mic action available; target state=" .. tostring(muteState))
      if showStatus then
        showAlert(alertForUnavailableTeamsMicControl(muteState))
      end
      return
    end
    if showStatus then
      showAlert(alertForMuteState(muteState))
    end
    return
  end

  if attempt >= 20 then
    log("Teams did not become frontmost; skipped mic update")
    if showStatus then
      showAlert("Teams did not focus")
    end
    return
  end

  hs.timer.doAfter(0.05, function()
    handleTeamsWhenFrontmost(teams, muteState, requestGeneration, showStatus, attempt + 1)
  end)
end

local function handleZoomTarget(zoom, muteState, requestGeneration, showStatus)
  if not isLatestMeetingRequest(requestGeneration) then
    return
  end

  local settleRemaining = (zoomLastPressAt + zoomPostPressSettleSeconds) - hs.timer.secondsSinceEpoch()
  if settleRemaining > 0 then
    log("Zoom audio menu is settling; queued target state=" .. tostring(muteState) .. " wait=" .. string.format("%.2f", settleRemaining))
    hs.timer.doAfter(settleRemaining, function()
      if isLatestMeetingRequest(requestGeneration) then
        handleZoomTarget(zoom, muteState, requestGeneration, showStatus)
      end
    end)
    return
  end

  log("Activating Zoom before mic update; target state=" .. tostring(muteState))
  zoom:activate(true)
  hs.timer.doAfter(meetingActivationDelaySeconds, function()
    if isLatestMeetingRequest(requestGeneration) then
      handleZoomWhenFrontmost(zoom, muteState, requestGeneration, showStatus)
    end
  end)
end

local function handleTeamsTarget(teams, muteState, requestGeneration, showStatus)
  if not isLatestMeetingRequest(requestGeneration) then
    return
  end

  log("Activating Teams before mic update; target state=" .. tostring(muteState))
  teams:activate(true)
  hs.timer.doAfter(meetingActivationDelaySeconds, function()
    if isLatestMeetingRequest(requestGeneration) then
      handleTeamsWhenFrontmost(teams, muteState, requestGeneration, showStatus)
    end
  end)
end

-- Priority is intentionally pragmatic: Google Meet can fit here later by
-- detecting a browser tab before Teams, but Zoom wins today when it is open.
local meetingAppTargets = {
  { name = "Zoom", find = findZoom, handle = handleZoomTarget },
  { name = "Teams", find = findTeams, handle = handleTeamsTarget },
}

local function findMeetingAppTarget()
  for _, target in ipairs(meetingAppTargets) do
    local app = target.find()
    if app then
      log("Selected meeting app target=" .. target.name)
      return target, app
    end
  end
  return nil, nil
end

local runMeetingReconciliation

local function scheduleMeetingReconciliation(requestGeneration, attempt, delaySeconds)
  hs.timer.doAfter(delaySeconds, function()
    if isLatestMeetingRequest(requestGeneration) then
      runMeetingReconciliation(requestGeneration, attempt)
    end
  end)
end

runMeetingReconciliation = function(requestGeneration, attempt)
  if not isLatestMeetingRequest(requestGeneration) then
    return
  end

  local targetMuteState = desiredMuteState
  if not muteStates[targetMuteState] then
    log("No valid desired mute state to reconcile: " .. tostring(targetMuteState))
    return
  end

  local target, app = findMeetingAppTarget()
  if not target then
    if attempt == 1 then
      showAlert("No supported meeting app is running")
    end
  else
    log("Reconciliation attempt=" .. tostring(attempt) .. " target=" .. target.name .. " desired LED state=" .. targetMuteState)
    target.handle(app, targetMuteState, requestGeneration, attempt == 1)
    log("Reconciliation attempted for desired LED state; continuing verification")
  end

  if attempt >= maxReconciliationAttempts then
    log("Reconciliation window ended for desired LED state=" .. tostring(desiredMuteState))
    return
  end

  scheduleMeetingReconciliation(requestGeneration, attempt + 1, reconciliationIntervalSeconds)
end

local function requestMeetingReconciliation(muteState, reason)
  if not muteStates[muteState] then
    log("Ignored unknown mute state: " .. tostring(muteState))
    return
  end

  desiredMuteState = muteState
  reconciliationGeneration = reconciliationGeneration + 1
  local requestGeneration = reconciliationGeneration
  log("Requested meeting reconciliation reason=" .. tostring(reason) .. " desired LED state=" .. muteState)
  runMeetingReconciliation(requestGeneration, 1)
end

local function toggleMeetingMute(muteState)
  requestMeetingReconciliation(muteState, "serial-toggle")
end

_G.toggleMeetingMuteFromArduinoButton = toggleMeetingMute
_G.toggleTeamsMuteFromArduinoButton = toggleMeetingMute

local function handleSerialLine(line)
  if not debugHeartbeats and line:match("^heartbeat ") then
    return
  end
  log("Serial line: " .. line)
  if line:match("^pressed%-toggle") then
    toggleMeetingMute(line:match("state=(%w+)"))
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

  closeSerialPortObject(serialPort, reason)
  if _G.muteButtonSerialPort == serialPort then
    _G.muteButtonSerialPort = nil
  end
  serialPort = nil
  serialBuffer = ""
end

hs.shutdownCallback = function()
  closeSerialPort("shutdown cleanup")
end

local openSerialPort

local function scheduleSerialOpen(delaySeconds)
  serialReconnectGeneration = serialReconnectGeneration + 1
  local generation = serialReconnectGeneration
  hs.timer.doAfter(delaySeconds, function()
    if generation == serialReconnectGeneration and configGeneration == _G.muteButtonConfigGeneration then
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
    showAlert("Arduino serial port not found")
    return
  end

  _G.muteButtonSerialPort = serialPort
  serialPort:baudRate(serialBaudRate)
  serialPort:dtr(false)
  serialPort:rts(false)
  serialPort:callback(function(_, callbackType, message)
    if configGeneration ~= _G.muteButtonConfigGeneration then
      return
    end

    if callbackType == "received" then
      handleSerialData(message)
    elseif callbackType == "removed" or callbackType == "closed" then
      log("Serial callback: " .. tostring(callbackType))
      closeSerialPort(callbackType)
      scheduleSerialOpen(1)
      showAlert("Arduino serial disconnected")
    elseif callbackType == "error" then
      log("Serial callback: " .. tostring(callbackType))
      log("Arduino serial error: " .. tostring(message))
      closeSerialPort("error")
      scheduleSerialOpen(1)
      showAlert("Arduino serial error: " .. tostring(message))
    end
  end)

  if serialPort:open() then
    log("Arduino serial connected")
    showAlert("Arduino mute button connected")
  else
    log("Could not open Arduino serial port")
    closeSerialPort("open failed")
    showAlert("Could not open Arduino serial port")
  end
end

hs.serial.deviceCallback(function()
  log("Serial device list changed")
  closeSerialPort("device list changed")
  scheduleSerialOpen(1)
end)

scheduleSerialOpen(1)
showAlert("Mute button config loaded")
log("Mute button config loaded")
