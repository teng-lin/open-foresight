"""Package application OAuth registration; never package account authorization."""
import json
import os
import re

SECRET_NAME = 'FORESIGHT_GOOGLE_CLIENT_JSON'


def release_google_client(path=None, environment=None, *, required=False):
    environment = os.environ if environment is None else environment
    raw = path.read_text() if path is not None else environment.get(SECRET_NAME, '')
    if not raw:
        if required:
            raise ValueError('Google sign-in releases require FORESIGHT_GOOGLE_CLIENT_JSON or --google-client')
        return None
    # Keep parser/provider errors from echoing application credentials in CI.
    try:
        config = json.loads(raw)
        installed = config['installed']
        if set(config) != {'installed'} or not isinstance(installed, dict):
            raise ValueError()
        allowed = {'client_id', 'client_secret', 'project_id', 'auth_uri',
                   'token_uri', 'auth_provider_x509_cert_url', 'redirect_uris'}
        if set(installed) - allowed:
            raise ValueError()
        client_id = installed['client_id']
        secret = installed.get('client_secret', '')
        if not isinstance(client_id, str) or not re.fullmatch(
                r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com', client_id):
            raise ValueError()
        if not isinstance(secret, str):
            raise ValueError()
        return {'installed': {'client_id': client_id, 'client_secret': secret}}
    except (ValueError, TypeError, KeyError):
        raise ValueError('Supply Google Desktop application OAuth JSON, never account tokens') from None


def write_google_client(path, configuration, *, mode=0o600):
    path.write_text(json.dumps(configuration) + '\n')
    path.chmod(mode)
