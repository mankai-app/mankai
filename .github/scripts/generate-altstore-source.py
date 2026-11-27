"""Generate an AltStore Classic source for an unsigned Mankai IPA."""

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
from zipfile import ZipFile


def generate_source(ipa_path, channel, release_date, download_url, icon_url):
    with ZipFile(ipa_path) as ipa:
        app_plists = [
            name
            for name in ipa.namelist()
            if name.startswith("Payload/")
            and name.endswith(".app/Info.plist")
            and name.count("/") == 2
        ]
        if len(app_plists) != 1:
            raise ValueError(f"{ipa_path} must contain exactly one app in Payload")
        app_info = plistlib.loads(ipa.read(app_plists[0]))

    with ipa_path.open("rb") as ipa_file:
        checksum = hashlib.file_digest(ipa_file, "sha256").hexdigest()

    return {
        "name": f"Mankai {channel.capitalize()}",
        "website": "https://mankai.app",
        "apps": [
            {
                "name": "Mankai",
                "bundleIdentifier": app_info["CFBundleIdentifier"],
                "developerName": "Travis Xu",
                "localizedDescription": "An extensible manga reader and library manager.",
                "iconURL": icon_url,
                "versions": [
                    {
                        "version": app_info["CFBundleShortVersionString"],
                        "buildVersion": app_info["CFBundleVersion"],
                        "date": release_date,
                        "downloadURL": download_url,
                        "size": ipa_path.stat().st_size,
                        "sha256": checksum,
                        "minOSVersion": app_info["MinimumOSVersion"],
                    }
                ],
                # The release workflow builds unsigned IPAs.
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {
                        key: value
                        for key, value in app_info.items()
                        if key.endswith("UsageDescription")
                    },
                },
            }
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--channel", choices=("nightly", "stable"), required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--icon-url", required=True)
    args = parser.parse_args()

    source = generate_source(
        args.ipa, args.channel, args.date, args.download_url, args.icon_url
    )
    print(json.dumps(source, indent=2))


if __name__ == "__main__":
    main()
