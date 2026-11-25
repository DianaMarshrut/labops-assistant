"""Регрессионные тесты установщика: то, что он пишет, должно читаться gateway.py.

Гайд «Свой ИИ-сотрудник в Telegram» ломался на шаге 4: установщик клал токен
в ключ bot_token, а gateway читал telegram_bot_token. Тесты гоняют настоящее
jq-выражение из install.sh и скармливают результат функциям gateway.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).parent.parent
INSTALL_SH = REPO_ROOT / "install.sh"
CONFIG_TEMPLATE = REPO_ROOT / "templates" / "assistant-config.json"
GATEWAY_PY = REPO_ROOT / "gateway" / "gateway.py"

FAKE_TOKEN = "123456789:" + "A" * 35
OWNER_ID = 424242


@pytest.fixture(scope="module")
def gateway(tmp_path_factory: pytest.TempPathFactory) -> ModuleType:
    """Import gateway.py from a temp cwd (it creates state dirs on import).

    Args:
        tmp_path_factory: Pytest factory for a module-scoped temp dir.

    Returns:
        The imported gateway module.
    """
    pytest.importorskip("requests")
    workdir = tmp_path_factory.mktemp("gateway-cwd")
    old_cwd = Path.cwd()
    os.chdir(workdir)
    try:
        spec = importlib.util.spec_from_file_location("gateway_under_test", GATEWAY_PY)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        os.chdir(old_cwd)
    return module


def _install_sh_function(name: str) -> str:
    """Return the body of a bash function from install.sh.

    Args:
        name: Function name.

    Returns:
        Source text from the function header to its closing brace.
    """
    text = INSTALL_SH.read_text(encoding="utf-8")
    match = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", text, flags=re.DOTALL | re.MULTILINE)
    assert match, f"function {name} not found in install.sh"
    return match.group(0)


def _render_config_like_installer(token: str, owner_id: int) -> dict:
    """Render the config template and patch it with install.sh's own jq filter.

    Args:
        token: Bot token to inject.
        owner_id: Owner Telegram ID to inject.

    Returns:
        The resulting config as the gateway would load it.
    """
    if shutil.which("jq") is None:
        pytest.skip("jq is not installed")
    body = _install_sh_function("install_assistant")
    jq_filter = re.search(r"'(\.agents\.assistant\.[^']+)'", body)
    assert jq_filter, "jq filter not found in install_assistant"
    rendered = CONFIG_TEMPLATE.read_text(encoding="utf-8")
    for key, value in {"USER": "labops", "AGENT_NAME": "assistant", "USER_NAME": "friend"}.items():
        rendered = rendered.replace("{{" + key + "}}", value)
    result = subprocess.run(
        ["jq", "--arg", "tok", token, "--argjson", "ids", f"[{owner_id}]", jq_filter.group(1)],
        input=rendered,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def test_install_sh_syntax() -> None:
    """install.sh must parse with bash -n."""
    subprocess.run(["bash", "-n", str(INSTALL_SH)], check=True)


def test_template_uses_gateway_keys() -> None:
    """The config template must carry the keys gateway.py reads."""
    cfg = json.loads(CONFIG_TEMPLATE.read_text(encoding="utf-8"))
    agent = cfg["agents"]["{{AGENT_NAME}}"]
    assert "allowlist_user_ids" in cfg
    assert "allowed_user_ids" not in cfg
    assert "telegram_bot_token" in agent
    assert "bot_token" not in agent


def test_installer_config_is_accepted_by_gateway(gateway: ModuleType) -> None:
    """Config produced by install.sh yields the token and the owner's ID."""
    cfg = _render_config_like_installer(FAKE_TOKEN, OWNER_ID)
    assert gateway._resolve_telegram_token(cfg["agents"]["assistant"]) == FAKE_TOKEN
    assert gateway._resolve_allowlist(cfg) == [OWNER_ID]


def test_gateway_reads_legacy_keys(gateway: ModuleType) -> None:
    """Servers installed by older install.sh keep working without config edits."""
    assert gateway._resolve_telegram_token({"bot_token": FAKE_TOKEN}) == FAKE_TOKEN
    assert gateway._resolve_allowlist({"allowed_user_ids": [str(OWNER_ID)]}) == [OWNER_ID]
    assert gateway._resolve_allowlist({"allowlist_user_ids": [], "allowed_user_ids": []}) == []


def test_gateway_still_rejects_missing_token(gateway: ModuleType) -> None:
    """No token in any key must still fail loudly."""
    with pytest.raises(ValueError, match="No telegram token"):
        gateway._resolve_telegram_token({"telegram_bot_token": "", "bot_token": ""})


def test_sudoers_grants_no_package_manager() -> None:
    """Passwordless apt is root: the agent must not get it."""
    body = _install_sh_function("install_sudoers")
    assert not re.search(r"/usr/bin/apt(-get)?\b", body)


def test_supported_ubuntu_matches_guide() -> None:
    """The guide promises Ubuntu 22.04, 24.04 and 26.04."""
    text = INSTALL_SH.read_text(encoding="utf-8")
    match = re.search(r"^readonly SUPPORTED_UBUNTU=\(([^)]*)\)", text, flags=re.MULTILINE)
    assert match
    assert set(re.findall(r'"([0-9.]+)"', match.group(1))) == {"22.04", "24.04", "26.04"}


def test_system_python3_is_not_replaced() -> None:
    """Switching /usr/bin/python3 to 3.12 breaks apt_pkg on Ubuntu 22.04."""
    text = INSTALL_SH.read_text(encoding="utf-8")
    assert "update-alternatives --install /usr/bin/python3" not in text
    assert "update-alternatives --set python3" not in text
