from pathlib import Path


CONFIG = Path(__file__).resolve().parents[1] / "hammerspoon" / "init.lua"


def test_unavailable_teams_mic_control_alert_reports_led_state():
    config = CONFIG.read_text()

    assert "local function alertForUnavailableTeamsMicControl(muteState)" in config
    assert "Mic is muted (LED red). No call mic button found." in config
    assert "Mic is hot! (LED green). No call mic button found." in config
    assert "hs.alert.show(alertForUnavailableTeamsMicControl(muteState))" in config
    assert 'hs.alert.show("Teams focused; mic button not found")' not in config


def test_keyboard_shortcut_fallback_stays_disabled():
    config = CONFIG.read_text()

    assert "local sendKeyboardShortcut = false" in config
