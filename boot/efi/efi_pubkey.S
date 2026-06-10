// SPDX-License-Identifier: Apache-2.0
// efi_pubkey.S — embed the image-signing Ed25519 public key into the UEFI loader.
//
// U1g-3b: the loader verifies the signed SWOSKERN kernel A/B manifest against
// this key — the SAME image-signing root the kernel compiles in
// (kernel/security/trust_root.S). build/image_trust_root.bin is the Makefile's
// copy of models/dev-image-signing.pub (32 raw bytes). Assembled for the same
// aarch64 Windows/COFF target as the rest of the loader.

    .data
    .balign 8
    .globl efi_image_signing_pubkey
efi_image_signing_pubkey:
    .incbin "build/image_trust_root.bin"
