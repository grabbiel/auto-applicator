from __future__ import annotations

import os

import pytest

from src.config import (
    CONFIG_TEMPLATE,
    AppConfig,
    ConfigError,
    LLMSettings,
    SearchQuery,
    load_config,
    load_secrets,
    load_settings,
    read_yaml,
    write_env,
)


def test_template_config_is_valid():
    cfg = AppConfig.model_validate(read_yaml(CONFIG_TEMPLATE))
    assert cfg.dry_run is True
    assert cfg.limits.max_applies_per_run == 20
    assert cfg.llm.base_url == "http://localhost:11434/v1"
    assert cfg.llm.temperature == 0.0


def test_load_settings_creates_user_config(home):
    s = load_settings(home)
    assert s.paths.config_file.exists()
    assert s.profile is not None and s.profile.personal.first_name == "Jane"
    assert s.resume_path == home / "files" / "resume.pdf"
    assert oct(os.stat(home).st_mode & 0o777) == "0o700"


def test_search_query_accepts_single_strings():
    q = SearchQuery.model_validate({"keywords": "Data", "workplace_type": "Remote", "experience_level": "Associate"})
    assert q.workplace_type == ["Remote"]
    assert q.experience_level == ["Associate"]


def test_invalid_config_has_friendly_error(tmp_path):
    bad = tmp_path / "config.yaml"
    bad.write_text("search_queries:\n  - keywords: x\n    workplace_type: [Moon]\n")
    with pytest.raises(ConfigError, match="workplace_type"):
        load_config(bad)


def test_effective_model_variant():
    assert LLMSettings(text_model="qwen2.5:7b", num_ctx=8192).effective_text_model == "qwen2.5:7b-ctx8192"
    assert LLMSettings(text_model="llama3.1", num_ctx=4096).effective_text_model == "llama3.1:latest-ctx4096"
    assert LLMSettings(text_model="qwen2.5:7b", num_ctx=None).effective_text_model == "qwen2.5:7b"
    remote = LLMSettings(base_url="http://127.0.0.1:1234/v1", text_model="m")
    assert remote.effective_text_model == "m"


def test_write_env_roundtrip(tmp_path):
    env = tmp_path / ".env"
    write_env(env, {"IMAP_USER": "me@example.com", "IMAP_APP_PASSWORD": "abcd efgh $x#y", "ATS_DEFAULT_PASSWORD": "it's\"q"})
    assert oct(os.stat(env).st_mode & 0o777) == "0o600"
    s = load_secrets(env)
    assert s.imap_user == "me@example.com"
    assert s.imap_app_password.get_secret_value() == "abcd efgh $x#y"
    assert s.ats_default_password.get_secret_value() == "it's\"q"
    assert s.imap_configured
    write_env(env, {"IMAP_HOST": "imap.fastmail.com"})  # merge keeps existing values
    s = load_secrets(env)
    assert s.imap_host == "imap.fastmail.com" and s.imap_app_password.get_secret_value() == "abcd efgh $x#y"


def test_example_env_is_not_configured(settings):
    assert not settings.secrets.imap_configured
