// Copyright 2020 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// +build !plan9

#include "textflag.h"

// func memmove(to, from unsafe.Pointer, n uintptr)
TEXT runtime·memmove(SB), NOSPLIT, $0-24

	MOVQ	to+0(FP), DI
	MOVQ	from+8(FP), SI
	MOVQ	n+16(FP), CX

	// Doing the large compare first allows usage
	// of smaller register compares with CMPL afterwards.
	CMPQ	CX, $128
	JA large
	TESTL	CX, CX
	JZ move_0
	CMPL	CX, $3
	JB	move_1or2
	JE	move_3
	CMPL	CX, $8
	JB	move_4through7
	CMPL	CX, $16
	// Pointer size (8) needs to be moved aligned
	// to avoid partial update.
	JBE	move_8through16
	CMPL	CX, $32
	JBE	move_17through32
	CMPL	CX, $64
	JA	move_65through128
move_33through64:
	MOVOU	(SI), X0
	MOVOU	16(SI), X1
	MOVOU	-32(SI)(CX*1), X2
	MOVOU	-16(SI)(CX*1), X3
sse_tail:
	MOVOU	X0, (DI)
	MOVOU	X1, 16(DI)
	MOVOU	X2, -32(DI)(CX*1)
	MOVOU	X3, -16(DI)(CX*1)
move_0:
	RET
large:
	MOVOU	(SI), X0
	MOVOU	16(SI), X1
	MOVOU	-32(SI)(CX*1), X2
	MOVOU	-16(SI)(CX*1), X3
	MOVQ	DI, BX
	SUBQ	SI, BX
	CMPQ	BX, CX
	JC		backward
forward:
	MOVQ	DI, DX
	ANDL	$31, DX
	MOVL	$64, AX
	SUBQ	DX, AX
forward_sse_loop:
	MOVOU -32(SI)(AX*1), X4
	MOVOU -16(SI)(AX*1), X5
	MOVOA X4, -32(DI)(AX*1)
	MOVOA X5, -16(DI)(AX*1)
	ADDQ $32, AX
	CMPQ CX, AX
	JAE forward_sse_loop
	JMP sse_tail
backward:
	MOVQ    DI, DX
	ADDQ    CX, DX
	ANDL    $31, DX
	MOVQ    CX, AX
	SUBQ    DX, AX
backward_sse_loop:
	MOVOU -32(SI)(AX*1), X4
	MOVOU -16(SI)(AX*1), X5
	MOVOA X4, -32(DI)(AX*1)
	MOVOA X5, -16(DI)(AX*1)
	SUBQ	$32, AX
	CMPQ	AX, $32
	JAE	backward_sse_loop
	JMP	sse_tail

move_1or2:
	MOVB	(SI), AX
	MOVB	-1(SI)(CX*1), BX
	MOVB	AX, (DI)
	MOVB	BX, -1(DI)(CX*1)
	RET
move_3:
	MOVW	(SI), AX
	MOVB	2(SI), BX
	MOVW	AX, (DI)
	MOVB	BX, 2(DI)
	RET
move_4through7:
	MOVL	(SI), AX
	MOVL	-4(SI)(CX*1), BX
	MOVL	AX, (DI)
	MOVL	BX, -4(DI)(CX*1)
	RET
move_8through16:
	MOVQ	(SI), AX
	MOVQ	-8(SI)(CX*1), BX
	MOVQ	AX, (DI)
	MOVQ	BX, -8(DI)(CX*1)
	RET
move_17through32:
	MOVOU	(SI), X0
	MOVOU	-16(SI)(CX*1), X1
	MOVOU	X0, (DI)
	MOVOU	X1, -16(DI)(CX*1)
	RET
move_65through128:
	MOVOU	(SI), X0
	MOVOU	16(SI), X1
	MOVOU	32(SI), X2
	MOVOU	48(SI), X3
	MOVOU	-64(SI)(CX*1), X4
	MOVOU	-48(SI)(CX*1), X5
	MOVOU	-32(SI)(CX*1), X6
	MOVOU	-16(SI)(CX*1), X7
	MOVOU	X0, (DI)
	MOVOU	X1, 16(DI)
	MOVOU	X2, 32(DI)
	MOVOU	X3, 48(DI)
	MOVOU	X4, -64(DI)(CX*1)
	MOVOU	X5, -48(DI)(CX*1)
	MOVOU	X6, -32(DI)(CX*1)
	MOVOU	X7, -16(DI)(CX*1)
	RET
