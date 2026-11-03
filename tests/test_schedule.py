from __future__ import annotations

import plistlib

from src.schedule import LABEL, render_plist


def test_rendered_plist_is_valid(settings):
    settings.config.schedule.hour, settings.config.schedule.minute = 8, 5
    data = plistlib.loads(render_plist(settings, "/opt/homebrew/bin/uv").encode())
    assert data["Label"] == LABEL
    assert data["ProgramArguments"][0] == "/opt/homebrew/bin/uv" and data["ProgramArguments"][-1] == "--run"
    assert data["EnvironmentVariables"]["AA_HOME"] == str(settings.paths.home)
    assert [d["Weekday"] for d in data["StartCalendarInterval"]] == [1, 2, 3, 4, 5]
    assert all(d["Hour"] == 8 and d["Minute"] == 5 for d in data["StartCalendarInterval"])
    settings.config.schedule.weekdays_only = False
    data = plistlib.loads(render_plist(settings, "/x/uv").encode())
    assert data["StartCalendarInterval"] == [{"Hour": 8, "Minute": 5}]
