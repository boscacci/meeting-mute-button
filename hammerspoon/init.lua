local repoRoot = "/Users/rob/repos/mute-button"
local logPath = repoRoot .. "/hammerspoon-debug.log"
local debugHeartbeats = false
local alertDurationSeconds = 0.6
local inputCoalesceDelaySeconds = 0.20
local controllerIntervalSeconds = 0.20
local commandSettleSeconds = 0.90
local maxControllerAttempts = 30
local requiredStableMatches = 2
local serialPortPath = "/dev/cu.usbserial-0001"
local serialBaudRate = 115200
local maxAccessibilitySearchDepth = 24
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
local desiredStateVersion = 0
local controllerAttempt = 0
local stableReconciliationMatches = 0
local pendingControllerTimer = nil
local lastMeetingCommand = nil
local serialReconnectGeneration = 0
_G.muteButtonConfigGeneration = (_G.muteButtonConfigGeneration or 0) + 1
local configGeneration = _G.muteButtonConfigGeneration
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

local function stopTimerObject(timer, reason)
  if not timer then
    return
  end

  log("Stopping timer: " .. tostring(reason))
  pcall(function()
    timer:stop()
  end)
end

if _G.muteButtonControllerTimer then
  stopTimerObject(_G.muteButtonControllerTimer, "config reload cleanup")
  _G.muteButtonControllerTimer = nil
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

local function readZoomMicState(zoom)
  local title = zoomAudioMenuTitle(zoom)
  if not title then
    log("No Zoom mute/unmute audio menu item found")
    return nil
  end

  local currentZoomMicState = zoomMicStateFromMenuTitle(title)
  if not currentZoomMicState then
    log("Zoom audio menu item found, but state could not be inferred; menu item=" .. title)
    return nil
  end

  return {
    state = currentZoomMicState,
    control = title,
    description = title,
  }
end

local function applyZoomMicState(zoom, observation, targetMuteState)
  log("Pressing Zoom audio menu item: " .. observation.control .. " target state=" .. tostring(targetMuteState) .. " current state=" .. tostring(observation.state))
  local ok, selected = pcall(function()
    return zoom:selectMenuItem({ "Meeting", observation.control })
  end)
  local pressed = ok and selected == true
  log("Zoom audio selectMenuItem result=" .. tostring(pressed))
  return pressed
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

local function readTeamsMicState(teams)
  local appElement = hs.axuielement.applicationElement(teams)
  if not appElement then
    log("Could not get Teams accessibility root")
    return nil
  end

  local button, text = findMicButton(appElement, 0, {})
  if not button then
    log("No Teams mic/mute accessibility button found")
    return nil
  end

  local currentTeamsMicState = teamsMicStateFromButtonText(text)
  if not currentTeamsMicState then
    log("Teams mic button found, but state could not be inferred; text=" .. text)
    return nil
  end

  return {
    state = currentTeamsMicState,
    control = button,
    description = text,
  }
end

local function applyTeamsMicState(_, observation, targetMuteState)
  log("Mouse-clicking Teams mic button: " .. observation.description .. " target state=" .. tostring(targetMuteState) .. " current state=" .. tostring(observation.state))
  local clicked = clickElementCenter(observation.control)
  log("Teams mic mouse click result=" .. tostring(clicked))
  return clicked
end

-- Priority is intentionally pragmatic: Google Meet can fit here later by
-- detecting a browser tab before Teams, but Zoom wins today when it is open.
local meetingAppTargets = {
  { name = "Zoom", find = findZoom, read = readZoomMicState, apply = applyZoomMicState, unavailableAlert = alertForUnavailableZoomMicControl },
  { name = "Teams", find = findTeams, read = readTeamsMicState, apply = applyTeamsMicState, unavailableAlert = alertForUnavailableTeamsMicControl },
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

local runMeetingController

local function stopPendingControllerTimer(reason)
  stopTimerObject(pendingControllerTimer, reason)
  if _G.muteButtonControllerTimer == pendingControllerTimer then
    _G.muteButtonControllerTimer = nil
  end
  pendingControllerTimer = nil
end

local function scheduleMeetingController(delaySeconds, reason)
  stopPendingControllerTimer("reschedule " .. tostring(reason))
  local scheduledVersion = desiredStateVersion
  log("Scheduling meeting controller reason=" .. tostring(reason) .. " delay=" .. string.format("%.2f", delaySeconds) .. " desired LED state=" .. tostring(desiredMuteState) .. " version=" .. tostring(scheduledVersion))
  pendingControllerTimer = hs.timer.doAfter(delaySeconds, function()
    pendingControllerTimer = nil
    if _G.muteButtonControllerTimer then
      _G.muteButtonControllerTimer = nil
    end
    if configGeneration ~= _G.muteButtonConfigGeneration then
      log("Skipped stale meeting controller after config reload")
      return
    end
    if scheduledVersion ~= desiredStateVersion then
      log("Skipped stale meeting controller version=" .. tostring(scheduledVersion) .. " latest=" .. tostring(desiredStateVersion))
      return
    end
    runMeetingController(reason)
  end)
  _G.muteButtonControllerTimer = pendingControllerTimer
end

local function meetingCommandSettleRemaining()
  if not lastMeetingCommand then
    return 0
  end

  local remaining = (lastMeetingCommand.sentAt + commandSettleSeconds) - hs.timer.secondsSinceEpoch()
  if remaining > 0 then
    return remaining
  end
  return 0
end

local function retryMeetingController(delaySeconds, reason)
  if controllerAttempt >= maxControllerAttempts then
    local state = stateFor(desiredMuteState)
    log("Controller window ended for desired LED state=" .. tostring(desiredMuteState) .. " version=" .. tostring(desiredStateVersion))
    showAlert(state.alert .. " (LED " .. state.ledColor .. "; not verified)")
    return
  end

  scheduleMeetingController(delaySeconds, reason)
end

runMeetingController = function(reason)
  local targetMuteState = desiredMuteState
  if not muteStates[targetMuteState] then
    log("No valid desired mute state to reconcile: " .. tostring(targetMuteState))
    return
  end

  controllerAttempt = controllerAttempt + 1
  local target, app = findMeetingAppTarget()
  if not target then
    stableReconciliationMatches = 0
    if controllerAttempt == 1 then
      showAlert("No supported meeting app is running")
    end
    retryMeetingController(controllerIntervalSeconds, "no-target")
    return
  end

  log("Controller attempt=" .. tostring(controllerAttempt) .. " reason=" .. tostring(reason) .. " target=" .. target.name .. " desired LED state=" .. targetMuteState .. " version=" .. tostring(desiredStateVersion))
  if not isAppFrontmost(app) then
    stableReconciliationMatches = 0
    log("Activating " .. target.name .. " before mic update; target state=" .. tostring(targetMuteState))
    app:activate(true)
    retryMeetingController(controllerIntervalSeconds, "activate")
    return
  end

  local remaining = meetingCommandSettleRemaining()
  if remaining > 0 then
    stableReconciliationMatches = 0
    log("Meeting command is settling; ignoring app state until quiet window; desired LED state=" .. tostring(targetMuteState) .. " wait=" .. string.format("%.2f", remaining))
    scheduleMeetingController(remaining, "command-settle")
    return
  end

  local observation = target.read(app)
  if not observation then
    stableReconciliationMatches = 0
    log(target.name .. " is frontmost; no safe mic state observation available; target state=" .. tostring(targetMuteState))
    if controllerAttempt == 1 then
      showAlert(target.unavailableAlert(targetMuteState))
    end
    retryMeetingController(controllerIntervalSeconds, "read-unavailable")
    return
  end

  log("Observed meeting mic state target=" .. target.name .. " state=" .. observation.state .. " desired LED state=" .. targetMuteState .. " control=" .. tostring(observation.description))
  if observation.state == targetMuteState then
    stableReconciliationMatches = stableReconciliationMatches + 1
    log("Reconciliation stable match count=" .. tostring(stableReconciliationMatches) .. "/" .. tostring(requiredStableMatches))
    if stableReconciliationMatches >= requiredStableMatches then
      lastMeetingCommand = nil
      log("Reconciliation stable; desired LED state matches meeting app")
      return
    end
    retryMeetingController(controllerIntervalSeconds, "stable-confirm")
    return
  end

  stableReconciliationMatches = 0
  local applied = target.apply(app, observation, targetMuteState)
  log("Meeting command result=" .. tostring(applied) .. " target=" .. target.name .. " desired LED state=" .. targetMuteState)
  if not applied then
    showAlert(target.unavailableAlert(targetMuteState))
    retryMeetingController(controllerIntervalSeconds, "apply-failed")
    return
  end

  lastMeetingCommand = {
    appName = target.name,
    targetState = targetMuteState,
    version = desiredStateVersion,
    sentAt = hs.timer.secondsSinceEpoch(),
  }
  scheduleMeetingController(commandSettleSeconds, "command-settle")
end

local function requestMeetingReconciliation(muteState, reason)
  if not muteStates[muteState] then
    log("Ignored unknown mute state: " .. tostring(muteState))
    return
  end

  desiredMuteState = muteState
  desiredStateVersion = desiredStateVersion + 1
  controllerAttempt = 0
  stableReconciliationMatches = 0
  local state = stateFor(muteState)
  log("Requested meeting reconciliation reason=" .. tostring(reason) .. " desired LED state=" .. muteState .. " version=" .. tostring(desiredStateVersion))
  showAlert(state.alert .. " (LED " .. state.ledColor .. ")")
  scheduleMeetingController(inputCoalesceDelaySeconds, "input-coalesce")
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
  stopPendingControllerTimer("shutdown cleanup")
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
