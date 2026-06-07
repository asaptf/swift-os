// vm.swift — per-process AArch64 stage-1 address spaces (MMU-on half).
//
// C2: this is the Swift port of the per-process half of the former vm.c. The
// early, MMU-off bring-up tables and the VA-0x8000_0000 probe helpers stay in C
// (kernel/mm/vm_early.c). The functions here run with the MMU on, drawing 4 KiB
// page-table frames from the PMM (kernel/mm/pmm.swift). RAM is identity-mapped,
// so a physical frame address doubles as its kernel pointer.
//
// C2.1 placeholder: the per-process functions still live in vm_early.c at this
// step; the port lands in C2.2.
