"""Mutation tests for the release gate; no signing credentials or apps are changed."""
from copy import deepcopy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path

module_spec = importlib.util.spec_from_file_location('helper_profile', Path(__file__).resolve().parents[1] / 'scripts/verify-helper-provisioning.py')
validator = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(validator)
now = datetime(2026, 9, 30, tzinfo=timezone.utc)
profile = {
    'ApplicationIdentifierPrefix': ['TEAM'], 'TeamIdentifier': ['TEAM'],
    'DeveloperCertificates': [b'authorized-leaf'], 'ProvisionsAllDevices': True,
    'ExpirationDate': datetime(2027, 9, 30),
    'Entitlements': {'com.apple.application-identifier': 'TEAM.com.waifux.app.helper',
                     'com.apple.security.application-groups': ['group.com.waifux.app']},
}
signing = 'Identifier=com.waifux.app.helper\nTeamIdentifier=TEAM\nAuthority=Developer ID Application: Test\n'
entitlements = dict(profile['Entitlements'], **{'com.apple.developer.team-identifier': 'TEAM'})
validator.validate_profile(profile, now)
validator.validate_signature(profile, signing, entitlements, b'authorized-leaf')


def rejected(name, operation):
    try:
        operation()
    except ValueError:
        print('PASS ' + name)
    else:
        raise AssertionError(name + ' was accepted')


for name, key, value in [('wildcard', 'com.apple.application-identifier', 'TEAM.*'),
                         ('main App profile', 'com.apple.application-identifier', 'TEAM.com.waifux.app'),
                         ('wrong Group', 'com.apple.security.application-groups', ['group.other'])]:
    changed = deepcopy(profile)
    changed['Entitlements'][key] = value
    rejected(name, lambda: validator.validate_profile(changed, now))
for name, key, value in [('development profile', 'ProvisionsAllDevices', False),
                         ('expired profile', 'ExpirationDate', datetime(2025, 1, 1))]:
    changed = deepcopy(profile)
    changed[key] = value
    rejected(name, lambda: validator.validate_profile(changed, now))
rejected('unauthorized signing certificate', lambda: validator.validate_signature(profile, signing, entitlements, b'other-leaf'))
rejected('wrong signing team', lambda: validator.validate_signature(profile, signing.replace('TeamIdentifier=TEAM', 'TeamIdentifier=OTHER'), entitlements, b'authorized-leaf'))
rejected('development signing identity', lambda: validator.validate_signature(profile, signing.replace('Developer ID Application:', 'Apple Development:'), entitlements, b'authorized-leaf'))
changed_entitlements = dict(entitlements)
changed_entitlements.pop('com.apple.application-identifier')
rejected('App ID lost during manual signing', lambda: validator.validate_signature(profile, signing, changed_entitlements, b'authorized-leaf'))
print('HELPER_PROVISIONING_REGRESSION_PASSED')
