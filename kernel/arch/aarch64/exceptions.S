// exceptions.S — EL1 exception vector table for early bring-up.
//
// M1 only needs installed vectors and a reliable failure path. Later
// milestones replace this with full register save/restore and dispatch.

.section ".text.exceptions", "ax"
.align 11
.global el1_vector_table

el1_vector_table:
    .rept 16
        b       exception_entry
        .space 128 - 4
    .endr

.global exception_entry
exception_entry:
    bl      exception_handler
1:
    wfe
    b       1b
