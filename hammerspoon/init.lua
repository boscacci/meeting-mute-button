local repoRoot = "/Users/rob/repos/mute-button"
local logPath = repoRoot .. "/hammerspoon-debug.log"
local debugHeartbeats = false
local serialPortPath = "/dev/cu.usbserial-0001"
local serialBaudRate = 115200
local teamsBundleIds = {
  "com.microsoft.teams2",
  "com.microsoft.teams",
}

local serialPort = nil
local serialBuffer = ""
local lastToggleAt = 0

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

  local previousApp = hs.application.frontmostApplication()
  log("Sending Teams mute shortcut via System Events; target state=" .. tostring(muteState))

  local ok, result = hs.osascript.applescript([[
tell application "Microsoft Teams" to activate
delay 0.8
tell application "System Events" to keystroke "m" using {command down, shift down}
]])
  log("System Events mute shortcut ok=" .. tostring(ok) .. " result=" .. tostring(result))
  hs.alert.show(alertForMuteState(muteState))

  if previousApp and previousApp:bundleID() ~= teams:bundleID() then
    hs.timer.doAfter(0.3, function()
      log("Restoring previous app: " .. tostring(previousApp:name()))
      previousApp:activate()
    end)
  end
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

local function openSerialPort()
  if serialPort and serialPort:isOpen() then
    log("Serial port already open: " .. serialPortPath)
    return
  end

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
      hs.alert.show("Arduino serial disconnected")
    elseif callbackType == "error" then
      log("Serial callback: " .. tostring(callbackType))
      log("Arduino serial error: " .. tostring(message))
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
  hs.timer.doAfter(1, openSerialPort)
end)

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "M", toggleTeamsMute)
hs.timer.doAfter(1, openSerialPort)
hs.alert.show("Mute button config loaded")
log("Mute button config loaded")
