// Derived from Inferno's libkern/memmove-386.s (adapted for amd64)
// https://bitbucket.org/inferno-os/inferno-os/src/default/libkern/memmove-386.s
//
//         Copyright © 1994-1999 Lucent Technologies Inc. All rights reserved.
//         Revisions Copyright © 2000-2007 Vita Nuova Holdings Limited (www.vitanuova.com).  All rights reserved.
//         Portions Copyright 2009 The Go Authors. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// +build !plan9

#include "go_asm.h"
#include "textflag.h"

// See memmove Go doc for important implementation constraints.

// func memmove(to, from unsafe.Pointer, n uintptr)
TEXT runtime·memmove(SB), NOSPLIT, $0-24

	MOVQ	to+0(FP), DI
	MOVQ	from+8(FP), SI
	MOVQ	n+16(FP), BX

	CMPL	BX, $16
	JBE	len_0_16
	CMPL	BX, $32
	JBE	mm_16_32
	CMPL	BX, $64
	JBE	mm_32_64
	CMPL	BX, $128
	JBE	mm_64_128
	CMPQ	BX, $256
	JBE	sse2Unaligned

	TESTB	$1, runtime·useAVXmemmove(SB)
	JNZ	avxUnaligned
	JMP	sse2Unaligned

len_0_16:
	TESTB	$24, BX 
	JNZ	len_9_16
	TESTB	$4, BX
	// Possible Align nops
	JNZ	len_5_8
	TESTL	BX, BX
	JE	small_ret
	TESTB	$2, BX
	// Possible align
	JNE	len_3_4
	MOVBLZX -1(SI)(BX*1), CX
	MOVBLZX (SI), AX
	MOVB	CX, -1(DI)(BX*1)
	MOVB    AX, (DI)
small_ret:
	RET

len_3_4:
	MOVWLZX -2(SI)(BX*1), CX
	MOVWLZX (SI), AX
	MOVW	CX, -2(DI)(BX*1)
	MOVW	AX, (DI)
	RET

len_9_16:
	MOVQ	(SI), CX
	MOVQ	-8(SI)(BX*1), AX
	MOVQ	CX, (DI)
	MOVQ	AX, -8(DI)(BX*1)
	RET

len_5_8:
	MOVL	(SI), CX
	MOVL	-4(SI)(BX*1), AX
	MOVL	CX, (DI)
	MOVL	AX, -4(DI)(BX*1)
	RET

mm_16_32:
	MOVOU	(SI), X0
	MOVOU   -16(SI)(BX*1), X1
	MOVOU	X0, (DI)
	MOVOU	X1, -16(DI)(BX*1)
	RET

mm_32_64:
	MOVOU   (SI), X0
	MOVOU   16(SI), X1
	MOVOU   -16(SI)(BX*1), X2
	MOVOU   -32(SI)(BX*1), X3
	MOVOU   X0, (DI)
	MOVOU   X1, 16(DI)
	MOVOU   X2, -16(DI)(BX*1)
	MOVOU   X3, -32(DI)(BX*1)
	RET

mm_64_128:
	MOVOU   (SI), X0
	MOVOU   16(SI), X1
	MOVOU   32(SI), X2
	MOVOU   48(SI), X3
	MOVOU   -64(SI)(BX*1), X4
	MOVOU   -48(SI)(BX*1), X5
	MOVOU   -32(SI)(BX*1), X6
	MOVOU   -16(SI)(BX*1), X7
	MOVOU   X0, (DI)
	MOVOU   X1, 16(DI)
	MOVOU   X2, 32(DI)
	MOVOU   X3, 48(DI)
	MOVOU   X4, -64(DI)(BX*1)
	MOVOU   X5, -48(DI)(BX*1)
	MOVOU   X6, -32(DI)(BX*1)
	MOVOU   X7, -16(DI)(BX*1)
	RET



avxUnaligned:
	// There are two implementations of move algorithm.
	// The first one for non-overlapped memory regions. It uses forward copying.
	// The second one for overlapped regions. It uses backward copying
	MOVQ	DI, CX
	SUBQ	SI, CX
	// Now CX contains distance between SRC and DEST
	CMPQ	CX, BX
	// If the distance lesser than region length it means that regions are overlapped
	JC	avx_backward

	// Non-temporal copy would be better for big sizes.
	CMPQ	BX, $0x100000
	JAE	gobble_big_data_fwd

	// Memory layout on the source side
	// SI                                       CX
	// |<---------BX before correction--------->|
	// |       |<--BX corrected-->|             |
	// |       |                  |<--- AX  --->|
	// |<-R11->|                  |<-128 bytes->|
	// +----------------------------------------+
	// | Head  | Body             | Tail        |
	// +-------+------------------+-------------+
	// ^       ^                  ^
	// |       |                  |
	// Save head into Y4          Save tail into X5..X12
	//         |
	//         SI+R11, where R11 = ((DI & -32) + 32) - DI
	// Algorithm:
	// 1. Unaligned save of the tail's 128 bytes
	// 2. Unaligned save of the head's 32  bytes
	// 3. Destination-aligned copying of body (128 bytes per iteration)
	// 4. Put head on the new place
	// 5. Put the tail on the new place
	// It can be important to satisfy processor's pipeline requirements for
	// small sizes as the cost of unaligned memory region copying is
	// comparable with the cost of main loop. So code is slightly messed there.
	// There is more clean implementation of that algorithm for bigger sizes
	// where the cost of unaligned part copying is negligible.
	// You can see it after gobble_big_data_fwd label.
	LEAQ	(SI)(BX*1), CX
	MOVQ	DI, R10
	// CX points to the end of buffer so we need go back slightly. We will use negative offsets there.
	MOVOU	-0x80(CX), X5
	MOVOU	-0x70(CX), X6
	MOVQ	$0x80, AX
	// Align destination address to register width.
	ANDQ	$-32, DI
	ADDQ	$32, DI
	// Continue tail saving.
	MOVOU	-0x60(CX), X7
	MOVOU	-0x50(CX), X8
	// Make R11 delta between aligned and unaligned destination addresses.
	MOVQ	DI, R11
	SUBQ	R10, R11
	// Continue tail saving.
	MOVOU	-0x40(CX), X9
	MOVOU	-0x30(CX), X10
	// Let's make bytes-to-copy value adjusted as we've prepared unaligned part for copying.
	SUBQ	R11, BX
	// Continue tail saving.
	MOVOU	-0x20(CX), X11
	MOVOU	-0x10(CX), X12
	// The tail will be put on its place after main body copying.
	// It's time for the unaligned heading part.
	VMOVDQU	(SI), Y4
	// Adjust source address to point past head.
	ADDQ	R11, SI
	SUBQ	AX, BX
	// Aligned memory copying there
gobble_128_loop:
	VMOVDQU	(SI), Y0
	VMOVDQU	0x20(SI), Y1
	VMOVDQU	0x40(SI), Y2
	VMOVDQU	0x60(SI), Y3
	ADDQ	AX, SI
	VMOVDQA	Y0, (DI)
	VMOVDQA	Y1, 0x20(DI)
	VMOVDQA	Y2, 0x40(DI)
	VMOVDQA	Y3, 0x60(DI)
	ADDQ	AX, DI
	SUBQ	AX, BX
	JA	gobble_128_loop
	// Now we can store unaligned parts.
	ADDQ	AX, BX
	ADDQ	DI, BX
	VMOVDQU	Y4, (R10)
	VZEROUPPER
	MOVOU	X5, -0x80(BX)
	MOVOU	X6, -0x70(BX)
	MOVOU	X7, -0x60(BX)
	MOVOU	X8, -0x50(BX)
	MOVOU	X9, -0x40(BX)
	MOVOU	X10, -0x30(BX)
	MOVOU	X11, -0x20(BX)
	MOVOU	X12, -0x10(BX)
	RET

gobble_big_data_fwd:
	// There is forward copying for big regions.
	// It uses non-temporal mov instructions.
	// Details of this algorithm are commented previously for small sizes.
	LEAQ	(SI)(BX*1), CX
	MOVOU	-0x80(SI)(BX*1), X5
	MOVOU	-0x70(CX), X6
	MOVOU	-0x60(CX), X7
	MOVOU	-0x50(CX), X8
	MOVOU	-0x40(CX), X9
	MOVOU	-0x30(CX), X10
	MOVOU	-0x20(CX), X11
	MOVOU	-0x10(CX), X12
	VMOVDQU	(SI), Y4
	MOVQ	DI, R8
	ANDQ	$-32, DI
	ADDQ	$32, DI
	MOVQ	DI, R10
	SUBQ	R8, R10
	SUBQ	R10, BX
	ADDQ	R10, SI
	LEAQ	(DI)(BX*1), CX
	SUBQ	$0x80, BX
gobble_mem_fwd_loop:
	PREFETCHNTA 0x1C0(SI)
	PREFETCHNTA 0x280(SI)
	// Prefetch values were chosen empirically.
	// Approach for prefetch usage as in 7.6.6 of [1]
	// [1] 64-ia-32-architectures-optimization-manual.pdf
	// https://www.intel.ru/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-optimization-manual.pdf
	VMOVDQU	(SI), Y0
	VMOVDQU	0x20(SI), Y1
	VMOVDQU	0x40(SI), Y2
	VMOVDQU	0x60(SI), Y3
	ADDQ	$0x80, SI
	VMOVNTDQ Y0, (DI)
	VMOVNTDQ Y1, 0x20(DI)
	VMOVNTDQ Y2, 0x40(DI)
	VMOVNTDQ Y3, 0x60(DI)
	ADDQ	$0x80, DI
	SUBQ	$0x80, BX
	JA		gobble_mem_fwd_loop
	// NT instructions don't follow the normal cache-coherency rules.
	// We need SFENCE there to make copied data available timely.
	SFENCE
	VMOVDQU	Y4, (R8)
	VZEROUPPER
	MOVOU	X5, -0x80(CX)
	MOVOU	X6, -0x70(CX)
	MOVOU	X7, -0x60(CX)
	MOVOU	X8, -0x50(CX)
	MOVOU	X9, -0x40(CX)
	MOVOU	X10, -0x30(CX)
	MOVOU	X11, -0x20(CX)
	MOVOU	X12, -0x10(CX)
	RET

avx_backward:
	MOVQ	DI, AX
	// Backward copying is about the same as the forward one.
	// Firstly we load unaligned tail in the beginning of region.
	MOVOU	(SI), X5
	MOVOU	0x10(SI), X6
	ADDQ	BX, DI
	MOVOU	0x20(SI), X7
	MOVOU	0x30(SI), X8
	LEAQ	-0x20(DI), R10
	MOVQ	DI, R11
	MOVOU	0x40(SI), X9
	MOVOU	0x50(SI), X10
	ANDQ	$0x1F, R11
	MOVOU	0x60(SI), X11
	MOVOU	0x70(SI), X12
	XORQ	R11, DI
	// Let's point SI to the end of region
	ADDQ	BX, SI
	// and load unaligned head into X4.
	VMOVDQU	-0x20(SI), Y4
	SUBQ	R11, SI
	SUBQ	R11, BX
	// If there is enough data for non-temporal moves go to special loop
	CMPQ	BX, $0x100000
	JA		gobble_big_data_bwd
	SUBQ	$0x80, BX
gobble_mem_bwd_loop:
	VMOVDQU	-0x20(SI), Y0
	VMOVDQU	-0x40(SI), Y1
	VMOVDQU	-0x60(SI), Y2
	VMOVDQU	-0x80(SI), Y3
	SUBQ	$0x80, SI
	VMOVDQA	Y0, -0x20(DI)
	VMOVDQA	Y1, -0x40(DI)
	VMOVDQA	Y2, -0x60(DI)
	VMOVDQA	Y3, -0x80(DI)
	SUBQ	$0x80, DI
	SUBQ	$0x80, BX
	JA		gobble_mem_bwd_loop
	// Let's store unaligned data
	VMOVDQU	Y4, (R10)
	VZEROUPPER
	MOVOU	X5, (AX)
	MOVOU	X6, 0x10(AX)
	MOVOU	X7, 0x20(AX)
	MOVOU	X8, 0x30(AX)
	MOVOU	X9, 0x40(AX)
	MOVOU	X10, 0x50(AX)
	MOVOU	X11, 0x60(AX)
	MOVOU	X12, 0x70(AX)
	RET

gobble_big_data_bwd:
	SUBQ	$0x80, BX
gobble_big_mem_bwd_loop:
	PREFETCHNTA -0x1C0(SI)
	PREFETCHNTA -0x280(SI)
	VMOVDQU	-0x20(SI), Y0
	VMOVDQU	-0x40(SI), Y1
	VMOVDQU	-0x60(SI), Y2
	VMOVDQU	-0x80(SI), Y3
	SUBQ	$0x80, SI
	VMOVNTDQ	Y0, -0x20(DI)
	VMOVNTDQ	Y1, -0x40(DI)
	VMOVNTDQ	Y2, -0x60(DI)
	VMOVNTDQ	Y3, -0x80(DI)
	SUBQ	$0x80, DI
	SUBQ	$0x80, BX
	JA	gobble_big_mem_bwd_loop
	SFENCE
	VMOVDQU	Y4, (R10)
	VZEROUPPER
	MOVOU	X5, (AX)
	MOVOU	X6, 0x10(AX)
	MOVOU	X7, 0x20(AX)
	MOVOU	X8, 0x30(AX)
	MOVOU	X9, 0x40(AX)
	MOVOU	X10, 0x50(AX)
	MOVOU	X11, 0x60(AX)
	MOVOU	X12, 0x70(AX)
	RET

sse2Unaligned:
	// Test if it's within extent; if so, go backwards, else forwards.
	MOVQ	DI, CX
	SUBQ	SI, CX
	// Now CX contains distance between SRC and DEST
	CMPQ	CX, BX
	// If the distance lesser than region length it means that regions are overlapped
	JC	sse2_backward
	//CMPQ	BX, $0x100000
	//JAE	sse2_big_data_fwd

sse2_forward:
	LEAQ	(SI)(BX*1), CX
	MOVQ	DI, R10
	MOVOU	-0x40(CX), X5
	MOVOU	-0x30(CX), X6
	MOVQ	$64, AX

	ANDQ	$-16, DI
	ADDQ	$16, DI

	MOVOU	-0x20(CX), X7
	MOVOU	-0x10(CX), X8
	MOVQ	DI, R11
	SUBQ	R10, R11
	SUBQ	R11, BX
	MOVOU	(SI), X4
	ADDQ	R11, SI
	SUBQ	AX, BX

sse2_main_fwd:
	PREFETCHT0 128(SI)
	MOVOU	(SI), X0
	MOVOU	16(SI), X1
	MOVOU	32(SI), X2
	MOVOU	48(SI), X3
	ADDQ	AX, SI
	MOVAPS	X0, (DI)
	MOVAPS	X1, 16(DI)
	MOVAPS	X2, 32(DI)
	MOVAPS	X3, 48(DI)
	ADDQ	AX, DI
	SUBQ	AX, BX
	JA	sse2_main_fwd
	ADDQ	AX, BX
	ADDQ	DI, BX
	MOVOU	X4, (R10)
	MOVOU	X5, -0x40(BX)
	MOVOU	X6, -0x30(BX)
	MOVOU	X7, -0x20(BX)
	MOVOU	X8, -0x10(BX)
	RET



sse2_backward:
	MOVQ	DI, AX
	// Backward copying is about the same as the forward one.
	// Firstly we load unaligned tail in the beginning of region.
	MOVOU	(SI), X5
	MOVOU	0x10(SI), X6
	ADDQ	BX, DI
	MOVOU	0x20(SI), X7
	MOVOU	0x30(SI), X8
	LEAQ	-0x10(DI), R10
	MOVQ	DI, R11
	ANDQ	$0x0F, R11
	XORQ	R11, DI
	// Let's point SI to the end of region
	ADDQ	BX, SI
	// and load unaligned head into X4.
	MOVOU	-0x10(SI), X4
	SUBQ	R11, SI
	SUBQ	R11, BX
	SUBQ	$0x40, BX
sse2_mem_bwd_loop:
	MOVOU	-0x10(SI), X0
	MOVOU	-0x20(SI), X1
	MOVOU	-0x30(SI), X2
	MOVOU	-0x40(SI), X3
	SUBQ	$0x40, SI
	MOVAPS	X0, -0x10(DI)
	MOVAPS	X1, -0x20(DI)
	MOVAPS	X2, -0x30(DI)
	MOVAPS	X3, -0x40(DI)
	SUBQ	$0x40, DI
	SUBQ	$0x40, BX
	JA		sse2_mem_bwd_loop
	// Let's store unaligned data
	MOVOU	X4, (R10)
	MOVOU	X5, (AX)
	MOVOU	X6, 0x10(AX)
	MOVOU	X7, 0x20(AX)
	MOVOU	X8, 0x30(AX)
	RET
