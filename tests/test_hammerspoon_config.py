from pathlib import Path


CONFIG = Path(__file__).resolve().parents[1] / "hammerspoon" / "init.lua"
FIRMWARE = Path(__file__).resolve().parents[1] / "ButtonSerialTest" / "ButtonSerialTest.ino"


def test_hammerspoon_mute_state_mapping_is_led_color_source_of_truth():
    config = CONFIG.read_text()

    assert "local muteStates = {" in config
    assert 'muted = { name = "muted", ledColor = "red", alert = "Mic is muted" }' in config
    assert 'unmuted = { name = "unmuted", ledColor = "green", alert = "Mic is hot!" }' in config
    assert 'return state.alert .. " (LED " .. state.ledColor .. "). No call mic button found."' in config


def test_unavailable_teams_mic_control_alert_reports_led_state():
    config = CONFIG.read_text()

    assert "local function alertForUnavailableTeamsMicControl(muteState)" in config
    assert "local state = stateFor(muteState)" in config
    assert 'return state.alert .. " (LED " .. state.ledColor .. "). No call mic button found."' in config
    assert "showAlert(target.unavailableAlert(targetMuteState))" in config
    assert 'hs.alert.show("Teams focused; mic button not found")' not in config


def test_keyboard_shortcut_fallback_stays_disabled():
    config = CONFIG.read_text()

    assert "sendKeyboardShortcut" not in config
    assert "hs.eventtap.keyStroke" not in config
    assert "Command+Shift+A" not in config
    assert "Command+Shift+M" not in config


def test_hammerspoon_accessibility_helpers_are_consolidated():
    config = CONFIG.read_text()

    assert "local accessibilityTextAttributes = {" in config
    assert "local buttonRoles = {" in config
    assert "local function attributeValue(element, attribute)" in config
    assert "local function typedAttribute(element, attribute, expectedType)" in config


def test_teams_accessibility_search_reaches_current_call_toolbar_depth():
    config = CONFIG.read_text()

    assert "local maxAccessibilitySearchDepth = 24" in config
    assert "depth > maxAccessibilitySearchDepth" in config
    assert "depth > 14" not in config


def test_teams_mic_click_respects_led_target_state():
    config = CONFIG.read_text()

    assert "local function teamsMicStateFromButtonText(text)" in config
    assert 'return "muted"' in config
    assert 'return "unmuted"' in config
    assert "local function readTeamsMicState(teams)" in config
    assert "local function applyTeamsMicState(_, observation, targetMuteState)" in config
    assert "observation.state == targetMuteState" in config
    assert "Mouse-clicking Teams mic button:" in config


def test_zoom_is_prioritized_before_teams_when_running():
    config = CONFIG.read_text()

    assert "local meetingAppTargets = {" in config
    assert 'name = "Zoom"' in config
    assert 'name = "Teams"' in config
    assert config.index('name = "Zoom"') < config.index('name = "Teams"')
    assert "local target, app = findMeetingAppTarget()" in config
    assert "read = readZoomMicState" in config
    assert "apply = applyZoomMicState" in config


def test_zoom_mic_toggle_uses_accessibility_menu_item_not_keyboard_shortcut():
    config = CONFIG.read_text()

    assert "local zoomBundleIds = {" in config
    assert '"us.zoom.xos"' in config
    assert "local function zoomAudioMenuTitle(zoom)" in config
    assert 'zoom:findMenuItem({ "Meeting", "Unmute audio" })' in config
    assert 'zoom:selectMenuItem({ "Meeting", observation.control })' in config
    assert 'return "muted"' in config
    assert 'return "unmuted"' in config
    assert "local function readZoomMicState(zoom)" in config
    assert "local function applyZoomMicState(zoom, observation, targetMuteState)" in config
    assert "Command+Shift+A" not in config


def test_hammerspoon_accepts_rapid_meeting_state_changes():
    config = CONFIG.read_text()

    assert "lastToggleAt" not in config
    assert "Ignored duplicate toggle inside debounce window" not in config
    assert "desiredStateVersion = desiredStateVersion + 1" in config
    assert "scheduledVersion ~= desiredStateVersion" in config
    assert "Skipped stale meeting controller version=" in config


def test_hammerspoon_reconciles_latest_led_state_retroactively():
    config = CONFIG.read_text()

    assert "local desiredMuteState = nil" in config
    assert "local controllerIntervalSeconds = 0.20" in config
    assert "local maxControllerAttempts = 30" in config
    assert "local function requestMeetingReconciliation(muteState, reason)" in config
    assert "desiredMuteState = muteState" in config
    assert 'scheduleMeetingController(inputCoalesceDelaySeconds, "input-coalesce")' in config
    assert "retryMeetingController(controllerIntervalSeconds" in config
    assert "Observed meeting mic state target=" in config


def test_reconciliation_loop_is_single_flight_not_nested_timers():
    config = CONFIG.read_text()

    assert "local runMeetingController" in config
    assert "local pendingControllerTimer = nil" in config
    assert "stopPendingControllerTimer(\"reschedule \" .. tostring(reason))" in config
    assert config.count("runMeetingController(reason)") == 1
    assert "lastMeetingCommand = {" in config
    assert "local applied = target.apply(app, observation, targetMuteState)" in config
    assert "handleZoomWhenFrontmost" not in config
    assert "handleTeamsWhenFrontmost" not in config
    assert "meetingActivationDelaySeconds" not in config
    assert "hs.timer.doAfter(meetingActivationDelaySeconds" not in config


def test_reconciliation_stops_after_stable_matches_to_avoid_toggle_loops():
    config = CONFIG.read_text()

    assert "local requiredStableMatches = 2" in config
    assert "local stableReconciliationMatches = 0" in config
    assert "stableReconciliationMatches = stableReconciliationMatches + 1" in config
    assert "stableReconciliationMatches >= requiredStableMatches" in config
    assert "Reconciliation stable; desired LED state matches meeting app" in config
    assert "stableReconciliationMatches = 0" in config
    assert "Observed meeting mic state target=" in config
    assert "continuing verification" not in config


def test_hammerspoon_coalesces_rapid_button_presses_before_meeting_action():
    config = CONFIG.read_text()

    assert "local inputCoalesceDelaySeconds = 0.20" in config
    assert "local pendingControllerTimer = nil" in config
    assert "local function stopPendingControllerTimer(reason)" in config
    assert "local function scheduleMeetingController(delaySeconds, reason)" in config
    assert 'scheduleMeetingController(inputCoalesceDelaySeconds, "input-coalesce")' in config
    assert "runMeetingReconciliation(requestGeneration, 1)" not in config
    assert "target.handle(app, targetMuteState, requestGeneration, attempt == 1)" not in config


def test_hammerspoon_waits_for_in_flight_commands_before_trusting_app_state():
    config = CONFIG.read_text()

    assert "local commandSettleSeconds = 0.90" in config
    assert "local lastMeetingCommand = nil" in config
    assert "local function meetingCommandSettleRemaining()" in config
    assert "Meeting command is settling; ignoring app state until quiet window" in config
    assert "lastMeetingCommand = {" in config
    assert "version = desiredStateVersion" in config
    assert 'scheduleMeetingController(remaining, "command-settle")' in config


def test_meeting_command_retries_are_bounded_by_target():
    config = CONFIG.read_text()

    assert 'name = "Zoom", find = findZoom, read = readZoomMicState, apply = applyZoomMicState, maxCommandAttempts = 1' in config
    assert 'name = "Teams", find = findTeams, read = readTeamsMicState, apply = applyTeamsMicState, maxCommandAttempts = 2' in config
    assert "local function meetingCommandAttemptsExhausted(target, targetMuteState)" in config
    assert "local function nextMeetingCommandAttemptCount(targetName, targetMuteState)" in config
    assert "lastMeetingCommand.version == desiredStateVersion" in config
    assert "lastMeetingCommand.targetState == targetMuteState" in config
    assert "lastMeetingCommand.appName == targetName" in config
    assert "lastMeetingCommand.commandCount" in config
    assert "Meeting command already sent for desired LED state; retrying within target attempt budget" in config
    assert "Meeting command already sent for desired LED state; not retrying without a new button press" in config
    assert "app did not confirm" in config
    assert "local applied = target.apply(app, observation, targetMuteState)" in config
    assert config.index("meetingCommandAttemptsExhausted(target, targetMuteState)") < config.index("local applied = target.apply(app, observation, targetMuteState)")


def test_zoom_queues_latest_state_while_audio_menu_settles():
    config = CONFIG.read_text()

    assert "local commandSettleSeconds = 0.90" in config
    assert "local lastMeetingCommand = nil" in config
    assert "Meeting command is settling; ignoring app state until quiet window" in config
    assert "sentAt = hs.timer.secondsSinceEpoch()" in config


def test_status_alerts_are_short_and_replaced_for_rapid_feedback():
    config = CONFIG.read_text()

    assert "local alertDurationSeconds = 0.6" in config
    assert "local function showAlert(message, seconds)" in config
    assert "hs.alert.closeAll(0)" in config
    assert "hs.alert.show(message, nil, nil, seconds or alertDurationSeconds)" in config


def test_teams_mic_toggle_uses_mouse_click_for_webview_button():
    config = CONFIG.read_text()

    assert "local function clickElementCenter(element)" in config
    assert 'tableAttribute(element, "AXPosition")' in config
    assert 'tableAttribute(element, "AXSize")' in config
    assert "hs.eventtap.leftClick" in config
    assert "button:performAction(\"AXPress\")" not in config


def test_hammerspoon_rejects_unknown_state_and_exposes_single_manual_test_hook():
    config = CONFIG.read_text()

    assert "if not muteStates[muteState] then" in config
    assert "Ignored unknown mute state:" in config
    assert "_G.toggleMeetingMuteFromArduinoButton = toggleMeetingMute" in config
    assert "toggleTeamsMuteFromArduinoButton" not in config
    assert "toggleMeetingMute(line:match(\"state=(%w+)\"))" in config


def test_hammerspoon_binds_system_hide_hotkeys_through_hammerspoon():
    config = CONFIG.read_text()

    assert "local function hideFrontmostApplication()" in config
    assert "local function hideOtherApplications()" in config
    assert "local function showAllApplications()" in config
    assert 'hs.hotkey.bind({ "cmd" }, "H", hideFrontmostApplication)' in config
    assert 'hs.hotkey.bind({ "alt", "cmd" }, "H", hideOtherApplications)' in config
    assert 'hs.hotkey.bind({ "alt", "cmd", "shift" }, "H", showAllApplications)' in config


def test_hide_frontmost_hotkey_has_finder_escape_hatch_for_only_visible_app():
    config = CONFIG.read_text()

    assert "local function frontmostApplicationIsOnlyVisibleUserApp(frontmostApp)" in config
    assert "not app:isHidden()" in config
    assert 'hs.application.get("com.apple.finder")' in config
    assert 'finder:activate()' in config
    assert 'hs.timer.doAfter(0.05, function()' in config
    assert 'app:hide()' in config


def test_hammerspoon_closes_stale_serial_objects_after_reload():
    config = CONFIG.read_text()

    assert "_G.muteButtonConfigGeneration" in config
    assert "_G.muteButtonSerialPort" in config
    assert 'closeSerialPortObject(_G.muteButtonSerialPort, "config reload cleanup")' in config
    assert config.count('stopTimerObject(_G.muteButtonControllerTimer, "config reload cleanup")') == 1
    assert "configGeneration == _G.muteButtonConfigGeneration" in config


def test_hammerspoon_closes_serial_port_before_shutdown_or_reload():
    config = CONFIG.read_text()

    assert "hs.shutdownCallback = function()" in config
    assert 'closeSerialPort("shutdown cleanup")' in config


def test_serial_open_failure_schedules_retry():
    config = CONFIG.read_text()

    assert "local scheduleSerialOpen" in config
    assert "scheduleSerialOpen = function(delaySeconds, reason)" in config
    assert "Scheduling serial open reason=" in config
    assert 'scheduleSerialOpen(1, "open failed")' in config


def test_hammerspoon_requires_configured_usb_serial_and_device_id():
    config = CONFIG.read_text()

    assert 'local muteButtonDeviceId = "61D60974-E863-4DB8-B571-2F3B0943FD3E"' in config
    assert "local muteButtonUsbSerialNumber = nil" in config
    assert "local excludedSerialDeviceFingerprints = {" in config
    assert 'reason = "laundry ESP32 currently attached on this USB location"' in config
    assert 'usbSerialNumber = "0001"' in config
    assert "idVendor = 4292" in config
    assert "idProduct = 60000" in config
    assert "locationID = 18087936" in config
    assert 'productName = "CP2102 USB to UART Bridge Controller"' in config
    assert 'deviceSignature = "c41060ea000130303031000000ff0000"' in config
    assert "local serialCandidatePathTemplates = {" in config
    assert '"/dev/cu.usbserial-%s"' in config
    assert "local function discoverSerialCandidatePaths()" in config
    assert 'if not muteButtonUsbSerialNumber or muteButtonUsbSerialNumber == "" then' in config
    assert "Mute button USB serial number is not configured" in config
    assert "local function serialSuffixForPath(path)" in config
    assert "local function ioregUsbDeviceBlocksForSerialNumber(usbSerialNumber)" in config
    assert 'hs.execute("/usr/sbin/ioreg -p IOUSB -l -w 0", true)' in config
    assert 'line:match("^[%s|]*}%s*$")' in config
    assert "local function ioregDataProperty(block, propertyName)" in config
    assert "local function usbDeviceFingerprintMatches(block, fingerprint)" in config
    assert "local function serialCandidateExclusionReason(path)" in config
    assert "local exclusionReason = serialCandidateExclusionReason(path)" in config
    assert "Skipping excluded serial candidate path=" in config
    assert "hs.fs.attributes(path)" in config
    assert "table.sort(paths)" in config
    assert "local function verifySerialDeviceId(line)" in config
    assert "serialDeviceVerified = true" in config
    assert "Ignored serial line before verified mute button device id" in config
    assert 'closeSerialPort("device id mismatch")' in config
    assert "local function startSerialVerificationTimer()" in config
    assert "Serial verification timed out" in config
    assert '"/bin/ls -1 /dev/cu.* 2>/dev/null"' not in config


def test_serial_absence_is_quiet_and_retried():
    config = CONFIG.read_text()

    assert "local serialAbsentRetrySeconds = 5" in config
    assert "No mute button serial candidates found" in config
    assert 'scheduleSerialOpen(serialAbsentRetrySeconds, "no serial candidates")' in config
    assert "Arduino serial port not found" not in config


def test_firmware_mute_state_mapping_is_led_color_source_of_truth():
    firmware = FIRMWARE.read_text()

    assert "enum MuteState" in firmware
    assert "MuteState currentMuteState = UNMUTED;" in firmware
    assert "const MutePresentation *presentationFor(MuteState state)" in firmware
    assert 'MUTED, "muted", true, false, false' in firmware
    assert 'UNMUTED, "unmuted", false, true, true' in firmware
    assert "const MutePresentation *currentPresentation = presentationFor(currentMuteState);" in firmware


def test_firmware_announces_unique_mute_button_device_id():
    firmware = FIRMWARE.read_text()

    assert 'const char *MUTE_BUTTON_DEVICE_ID = "61D60974-E863-4DB8-B571-2F3B0943FD3E";' in firmware
    assert 'Serial.print("device-id=");' in firmware
    assert "Serial.println(MUTE_BUTTON_DEVICE_ID);" in firmware
