// SPDX-License-Identifier: Apache-2.0
// trust_root.S — the Ed25519 public key the base image must be signed with,
// embedded into the kernel at build time (I8). The kernel is the root of
// trust: it is loaded directly (-kernel) or embedded in the EFI loader, and
// everything else — every binary, the identity store, the model trust root —
// comes from the base image this key authenticates at mount.
//
// build/image_trust_root.bin is copied from the dev image-signing public key
// (models/dev-image-signing.pub, minted by `modelsign keygen`) by the Makefile.

.section .rodata
.balign 8
.global image_trust_root
image_trust_root:
.incbin "build/image_trust_root.bin"
