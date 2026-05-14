import sys
from unittest.mock import MagicMock

# Stub missing runtime dependencies so rest.py and rest_proxy.py can be
# imported without a full JovianDSS installation.
for mod in ('oslo_utils', 'oslo_utils.netutils',
            'requests', 'urllib3', 'retry', 'toml'):
    sys.modules.setdefault(mod, MagicMock())
