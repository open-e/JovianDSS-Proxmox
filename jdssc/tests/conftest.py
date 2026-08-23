import sys
from unittest.mock import MagicMock

# Stub missing runtime dependencies so rest.py and rest_proxy.py can be
# imported without a full JovianDSS installation. 'retry.api' is listed
# explicitly: rest_proxy imports retry_call from it, and a MagicMock for
# 'retry' alone does not make the submodule importable.
for mod in ('oslo_utils', 'oslo_utils.netutils',
            'requests', 'urllib3', 'retry', 'retry.api', 'toml'):
    sys.modules.setdefault(mod, MagicMock())
