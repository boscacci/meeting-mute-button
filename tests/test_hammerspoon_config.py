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
    assert "hs.alert.show(alertForUnavailableTeamsMicControl(muteState))" in config
    assert 'hs.alert.show("Teams focused; mic button not found")' not in config


def test_keyboard_shortcut_fallback_stays_disabled():
    config = CONFIG.read_text()

    assert "local sendKeyboardShortcut = false" in config


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
    assert "clickTeamsMicButton(teams, muteState)" in config
    assert "currentTeamsMicState == targetMuteState" in config
    assert "Teams mic already matches LED state; no click needed; state=" in config


def test_firmware_mute_state_mapping_is_led_color_source_of_truth():
    firmware = FIRMWARE.read_text()

    assert "enum MuteState" in firmware
    assert "MuteState currentMuteState = UNMUTED;" in firmware
    assert "const MutePresentation *presentationFor(MuteState state)" in firmware
    assert 'MUTED, "muted", true, false, false' in firmware
    assert 'UNMUTED, "unmuted", false, true, true' in firmware
    assert "const MutePresentation *currentPresentation = presentationFor(currentMuteState);" in firmware
