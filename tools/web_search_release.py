"""Bundle distribution-owned search credentials without end-user project setup."""

import os
import shlex

KEYS = ("FORESIGHT_SEARCH_API_KEY", "FORESIGHT_WEB_CONTENT_API_KEY")


def release_web_search_keys(environment=None):
    environment = os.environ if environment is None else environment
    values = {key: environment.get(key, "") for key in KEYS}
    if not any(values.values()):
        return {}
    if not all(values.values()):
        raise ValueError(
            "Web-search releases require both search and web-content credentials"
        )
    return values


def shell_web_search_keys(values):
    return "\n".join(
        f"export {key}={shlex.quote(values[key])}" for key in KEYS if key in values
    )
