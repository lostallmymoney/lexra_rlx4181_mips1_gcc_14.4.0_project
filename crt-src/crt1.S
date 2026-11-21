/* Replacement crt1.o _start for Lexra-class (RTL8196E) targets.
 *
 * uClibc-ng's own prebuilt crt1.o (from this toolchain's sysroot) is
 * compiled for a generic interlocked-load MIPS32 pipeline and omits the
 * load-delay-slot filler instruction real R2000/R3000-class pipelines
 * (and Lexra, which is tuned identically - see mips_tune ==
 * PROCESSOR_R3000 || TARGET_LEXRA in a Lexra-aware GCC) require between
 * a load and the first use of its result. Concretely, the prebuilt
 * crt1.o does `lw $25, %call16(__uClibc_main)($gp)` immediately followed
 * by `jalr $25` with no filler in between; on real (non-interlocked)
 * Lexra silicon $25 has not been updated by the load yet, so the jalr
 * jumps to garbage and the process dies (observed as SIGBUS on real
 * hardware; not reproducible under QEMU's user-mode MIPS emulation,
 * which always interlocks loads).
 *
 * This reproduces the exact instruction sequence of this toolchain's own
 * crt1.o (verified via objdump - same _gp_disp-based $gp computation,
 * same register usage) with the load-delay filler nops a working period
 * Realtek/Lexra SDK crt1.o has at the same two points added back in.
 * Uses .set noreorder throughout and places nops explicitly so the
 * sequence exactly matches what was verified working, rather than
 * relying on any assembler pseudo-op (e.g. .cpload) that might take a
 * different code path than upstream crt1.o's own $gp setup.
 */

	.set	noreorder
	.text
	.globl	__start
	.ent	__start
__start:
	move	$31, $0
	bal	1f
	nop
1:
	lui	$28, %hi(_gp_disp)
	addiu	$28, $28, %lo(_gp_disp)
	addu	$28, $28, $31
	move	$31, $0

	lw	$4, %got(main)($28)
	lw	$5, 0($29)
	addiu	$6, $29, 4

	li	$1, -8
	and	$29, $29, $1
	addiu	$29, $29, -32

	lw	$7, %got(_init)($28)
	lw	$8, %got(_fini)($28)
	nop
	sw	$8, 16($29)
	sw	$2, 20($29)
	sw	$29, 24($29)

	lw	$25, %call16(__uClibc_main)($28)
	nop
	jalr	$25
	nop
	.end	__start

	.globl	hlt
	.ent	hlt
hlt:
	b	hlt
	nop
	.end	hlt
