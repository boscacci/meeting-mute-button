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
    assert "showAlert(alertForUnavailableTeamsMicControl(muteState))" in config
    assert 'hs.alert.show("Teams focused; mic button not found")' not in config


def test_keyboard_shortcut_fallback_stays_disabled():
    config = CONFIG.read_text()

    assert "sendKeyboardShortcut" not in config
    assert "hs.eventtap.keyStroke" not in config
    assert '"cmd", "shift"' not in config
    assert "Command+Shift+A" not in config


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
    assert "handleTeamsMicState(teams, muteState, actionAllowed)" in config
    assert "currentTeamsMicState == targetMuteState" in config
    assert "Teams mic already matches LED state; no click needed; state=" in config


def test_zoom_is_prioritized_before_teams_when_running():
    config = CONFIG.read_text()

    assert "local meetingAppTargets = {" in config
    assert 'name = "Zoom"' in config
    assert 'name = "Teams"' in config
    assert config.index('name = "Zoom"') < config.index('name = "Teams"')
    assert "local target, app = findMeetingAppTarget()" in config
    assert "target.handle(app, targetMuteState, requestGeneration, attempt == 1)" in config


def test_zoom_mic_toggle_uses_accessibility_menu_item_not_keyboard_shortcut():
    config = CONFIG.read_text()

    assert "local zoomBundleIds = {" in config
    assert '"us.zoom.xos"' in config
    assert "local function zoomAudioMenuTitle(zoom)" in config
    assert 'zoom:findMenuItem({ "Meeting", "Unmute audio" })' in config
    assert 'zoom:selectMenuItem({ "Meeting", title })' in config
    assert 'return "muted"' in config
    assert 'return "unmuted"' in config
    assert "Zoom audio already matches LED state; no press needed; state=" in config
    assert "Command+Shift+A" not in config


def test_hammerspoon_accepts_rapid_meeting_state_changes():
    config = CONFIG.read_text()

    assert "lastToggleAt" not in config
    assert "Ignored duplicate toggle inside debounce window" not in config
    assert "reconciliationGeneration = reconciliationGeneration + 1" in config
    assert "requestGeneration == reconciliationGeneration" in config
    assert "Skipped stale meeting update generation=" in config


def test_hammerspoon_reconciles_latest_led_state_retroactively():
    config = CONFIG.read_text()

    assert "local desiredMuteState = nil" in config
    assert "local reconciliationIntervalSeconds = 0.25" in config
    assert "local maxReconciliationAttempts = 24" in config
    assert "local function requestMeetingReconciliation(muteState, reason)" in config
    assert "desiredMuteState = muteState" in config
    assert "runMeetingReconciliation(requestGeneration, 1)" in config
    assert "scheduleMeetingReconciliation(requestGeneration, attempt + 1, reconciliationIntervalSeconds)" in config
    assert "Reconciliation attempted for desired LED state; status=" in config


def test_reconciliation_loop_is_single_flight_not_nested_timers():
    config = CONFIG.read_text()

    assert 'local reconciliationResult = "pending"' in config
    assert "reconciliationResult = target.handle(app, targetMuteState, requestGeneration, attempt == 1)" in config
    assert 'return "pending"' in config
    assert 'return "acted"' in config
    assert 'return "matched"' in config
    assert "actionReconciliationGeneration ~= requestGeneration" in config
    assert "not pressing again for this button state" in config
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
    assert "Reconciliation attempted for desired LED state; status=" in config
    assert "continuing verification" not in config


def test_zoom_queues_latest_state_while_audio_menu_settles():
    config = CONFIG.read_text()

    assert "local zoomPostPressSettleSeconds" in config
    assert "local zoomLastPressAt = 0" in config
    assert "Zoom audio menu is settling; queued target state=" in config
    assert "zoomLastPressAt = hs.timer.secondsSinceEpoch()" in config


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


def test_hammerspoon_rejects_unknown_state_and_has_no_manual_toggle_path():
    config = CONFIG.read_text()

    assert "if not muteStates[muteState] then" in config
    assert "Ignored unknown mute state:" in config
    assert "hs.hotkey.bind" not in config


def test_hammerspoon_closes_stale_serial_objects_after_reload():
    config = CONFIG.read_text()

    assert "_G.muteButtonConfigGeneration" in config
    assert "_G.muteButtonSerialPort" in config
    assert 'closeSerialPortObject(_G.muteButtonSerialPort, "config reload cleanup")' in config
    assert "configGeneration == _G.muteButtonConfigGeneration" in config


def test_hammerspoon_closes_serial_port_before_shutdown_or_reload():
    config = CONFIG.read_text()

    assert "hs.shutdownCallback = function()" in config
    assert 'closeSerialPort("shutdown cleanup")' in config


def test_firmware_mute_state_mapping_is_led_color_source_of_truth():
    firmware = FIRMWARE.read_text()

    assert "enum MuteState" in firmware
    assert "MuteState currentMuteState = UNMUTED;" in firmware
    assert "const MutePresentation *presentationFor(MuteState state)" in firmware
    assert 'MUTED, "muted", true, false, false' in firmware
    assert 'UNMUTED, "unmuted", false, true, true' in firmware
    assert "const MutePresentation *currentPresentation = presentationFor(currentMuteState);" in firmware
