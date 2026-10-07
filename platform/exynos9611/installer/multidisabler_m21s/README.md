# M21s Android 17 multidisabler

This recovery package is intentionally specific to the SM-F415F/M21s port.
It preserves the F415F file-based-encryption contract for `/data` without
applying the destructive Android 9-11 Samsung multidisabler actions.

It preserves TEEgris, Keymaster, Keystore2, VaultKeeper, PROCA, CASS and WSM.
Those services are part of the M21s security and storage startup chain and
must not be commented out or removed from VINTF manifests.

Build the package with:

```sh
platform/exynos9611/installer/multidisabler_m21s/build.sh
```

The ZIP restores the validated M21s FBE userdata contract
(`fileencryption=aes-256-xts:aes-256-cts:v1`), removes the incompatible Android 17
`encryption=None` `/data/data` initialization rule if present, and disables
restoration of the stock recovery. Flash it after formatting `/data` when
moving from an old unencrypted test installation so vold can create fresh FBE
metadata and CE keys.

The package deliberately does not import the S24+'s
`metadata_encryption=...:wrappedkey_v0` contract. That option depends on the
donor's wrapped-key KeyMint/TEE implementation; the M21s uses its native
F415F Keymaster path with the public AES-256-XTS/CTS v1 policy while the
Android 17 framework is ported around it.
