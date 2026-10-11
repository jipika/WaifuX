#!/usr/bin/env python3
"""Validate the Helper's Developer ID profile and its signed App Group identity."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

HELPER_ID = 'com.waifux.app.helper'
GROUP_ID = 'group.com.waifux.app'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_profile(profile, now=None):
    entitlements = profile.get('Entitlements', {})
    identifier = entitlements.get('com.apple.application-identifier', '')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    require(identifier in [prefix + '.' + HELPER_ID for prefix in prefixes],
            'profile 必须明确授权 com.waifux.app.helper，不能使用主 App、扩展或 wildcard profile')
    require(GROUP_ID in entitlements.get('com.apple.security.application-groups', []),
            'Helper profile 未授权 group.com.waifux.app')
    require(profile.get('ProvisionsAllDevices') is True,
            '正式打包需要 Developer ID 分发 profile，不能使用设备限定的开发 profile')
    require(not entitlements.get('com.apple.security.get-task-allow', entitlements.get('get-task-allow', False)),
            '分发 profile 不能允许调试器附加')
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime), 'profile 缺少有效期')
    require(expiration.replace(tzinfo=timezone.utc) > (now or datetime.now(timezone.utc)),
            'Helper profile 已过期')
    require(profile.get('TeamIdentifier') and profile.get('DeveloperCertificates'),
            'profile 缺少团队或签名证书授权')
    return identifier


def validate_signature(profile, signing, entitlements, certificate):
    team = re.search(r'^TeamIdentifier=(.+)$', signing, re.M)
    identifier = re.search(r'^Identifier=(.+)$', signing, re.M)
    require(team and team.group(1) in profile['TeamIdentifier'], '签名团队与 Helper profile 不一致')
    require(identifier and identifier.group(1) == HELPER_ID, '实际签名 Bundle ID 不是 Helper')
    require(re.search(r'^Authority=Developer ID Application:', signing, re.M),
            '正式 Helper 必须使用 Developer ID Application 证书')
    require(certificate in profile['DeveloperCertificates'], '实际签名证书不在 Helper profile 的授权列表内')
    require(entitlements.get('com.apple.application-identifier') == profile['Entitlements']['com.apple.application-identifier'],
            '实际签名 App ID 与 Helper profile 不一致')
    require(entitlements.get('com.apple.developer.team-identifier') == team.group(1),
            '实际签名的团队 entitlement 不一致')
    require(GROUP_ID in entitlements.get('com.apple.security.application-groups', []),
            '实际签名缺少共享 App Group')
    require(not entitlements.get('com.apple.security.get-task-allow', False), '正式 Helper 签名不能允许调试器附加')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--prepare-entitlements', type=Path)
    parser.add_argument('--output-entitlements', type=Path)
    args = parser.parse_args()
    try:
        profile_path = args.app / 'Contents/embedded.provisionprofile'
        require(profile_path.is_file(), 'Helper 缺少 embedded.provisionprofile')
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(profile_path)]))
        application_id = validate_profile(profile)
        if args.prepare_entitlements:
            require(args.output_entitlements is not None, '必须指定输出 entitlements 路径')
            entitlements = plistlib.loads(args.prepare_entitlements.read_bytes())
            entitlements['com.apple.application-identifier'] = application_id
            entitlements['com.apple.developer.team-identifier'] = profile['TeamIdentifier'][0]
            args.output_entitlements.write_bytes(plistlib.dumps(entitlements))
            print('HELPER_DISTRIBUTION_ENTITLEMENTS_PREPARED')
            return
        signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(args.app)], check=True,
                                 capture_output=True, text=True).stderr
        with tempfile.TemporaryDirectory(prefix='waifux-helper-certificate-') as directory:
            entitlements_path = Path(directory) / 'entitlements.plist'
            subprocess.run(['codesign', '-d', '--entitlements', str(entitlements_path), '--xml', str(args.app)],
                           check=True, capture_output=True)
            entitlements = plistlib.loads(entitlements_path.read_bytes())
            prefix = str(Path(directory) / 'signer-')
            subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(args.app)],
                           check=True, capture_output=True)
            certificate = Path(prefix + '0').read_bytes()
        validate_signature(profile, signing, entitlements, certificate)
        subprocess.run(['codesign', '--verify', '--strict', str(args.app)], check=True)
        print('HELPER_DISTRIBUTION_PROFILE_PASSED')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Helper 发布签名校验失败：{error}\n')


if __name__ == '__main__':
    main()
