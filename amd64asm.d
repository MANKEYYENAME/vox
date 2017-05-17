/**
Copyright: Copyright (c) 2017 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/
module amd64asm;

enum Register : ubyte {AX, CX, DX, BX, SP, BP, SI, DI, R8, R9, R10, R11, R12, R13, R14, R15}
enum RegisterMax  = cast(Register)(Register.max+1);

enum ArgType : ubyte { BYTE, WORD, DWORD, QWORD }

bool regNeedsRexPrefix(ArgType argType)(Register reg) {
	static if (argType == ArgType.BYTE) return reg >= 4;
	else return false;
}

import std.string : format;
struct Imm8  { ubyte  value; enum argT = ArgType.BYTE;  string toString(){ return format("0X%02X", value); } }
struct Imm16 { ushort value; enum argT = ArgType.WORD;  string toString(){ return format("0X%02X", value); } }
struct Imm32 { uint   value; enum argT = ArgType.DWORD; string toString(){ return format("0X%02X", value); } }
struct Imm64 { ulong  value; enum argT = ArgType.QWORD; string toString(){ return format("0X%02X", value); } }
enum bool isAnyImm(I) = is(I == Imm64) || is(I == Imm32) || is(I == Imm16) || is(I == Imm8);


enum ubyte REX_PREFIX = 0b0100_0000;
enum ubyte REX_W      = 0b0000_1000;
enum ubyte REX_R      = 0b0000_0100;
enum ubyte REX_X      = 0b0000_0010;
enum ubyte REX_B      = 0b0000_0001;

enum LegacyPrefix : ubyte {
	// Prefix group 1
	LOCK = 0xF0, // LOCK prefix
	REPN = 0xF2, // REPNE/REPNZ prefix
	REP  = 0xF3, // REP or REPE/REPZ prefix
	// Prefix group 2
	CS = 0x2E, // CS segment override
	SS = 0x36, // SS segment override
	DS = 0x3E, // DS segment override
	ES = 0x26, // ES segment override
	FS = 0x64, // FS segment override
	GS = 0x65, // GS segment override
	BNT = 0x2E, // Branch not taken
	BT = 0x3E, // Branch taken
	// Prefix group 3
	OPERAND_SIZE = 0x66, // Operand-size override prefix
	// Prefix group 4
	ADDRESS_SIZE = 0x67, // Address-size override prefix
}

// place 1 MSB of register into appropriate bit field of REX prefix
ubyte regTo_Rex_W(Register reg) pure nothrow @nogc { return (reg & 0b1000) >> 0; } // 0100 WRXB
ubyte regTo_Rex_R(Register reg) pure nothrow @nogc { return (reg & 0b1000) >> 1; } // 0100 WRXB
ubyte regTo_Rex_X(Register reg) pure nothrow @nogc { return (reg & 0b1000) >> 2; } // 0100 WRXB
ubyte regTo_Rex_B(Register reg) pure nothrow @nogc { return (reg & 0b1000) >> 3; } // 0100 WRXB

// place 3 LSB of register into appropriate bit field of ModR/M byte
ubyte regTo_ModRm_Reg(Register reg) pure nothrow @nogc { return (reg & 0b0111) << 3; }
ubyte regTo_ModRm_Rm(Register reg) pure nothrow @nogc { return (reg & 0b0111) << 0; }

struct SibScale { ubyte bits; ubyte value() { return cast(ubyte)(1 << bits); } }
struct ModRmMod { ubyte bits; }

ubyte encodeSibByte(SibScale ss, Register index, Register base) pure nothrow @nogc {
	return cast(ubyte)(ss.bits << 6) | (index & 0b0111) << 3 | (base & 0b0111);
}

ubyte encodeModRegRmByte(ModRmMod mod, Register reg, Register rm) pure nothrow @nogc {
	return cast(ubyte)(mod.bits << 6) | (reg & 0b0111) << 3 | (rm & 0b0111);
}

enum MemAddrType : ubyte {
	disp32,           // [                     disp32]
	indexDisp32,      // [       (index * s) + disp32]
	base,             // [base                       ]
	baseDisp32,       // [base +             + disp32]
	baseIndex,        // [base + (index * s)         ]
	baseIndexDisp32,  // [base + (index * s) + disp32]
	baseDisp8,        // [base +             + disp8 ]
	baseIndexDisp8    // [base + (index * s) + disp8 ]
}

ubyte[8] memAddrType_to_mod = [0,0,0,2,0,2,1,1];
ubyte[8] memAddrType_to_dispType = [1,1,0,1,0,1,2,2]; // 0 - none, 1 - disp32, 2 - disp8

// memory location that can be passed to assembly instructions
struct MemAddress {
	MemAddrType type;
	Register indexReg = Register.SP;
	Register baseReg  = Register.BP;
	SibScale scale;
	int disp32; // disp8 is stored here too
	byte disp8() @property { return cast(byte)(disp32 & 0xFF); }

	ubyte rexBits() { return regTo_Rex_X(indexReg) | regTo_Rex_B(baseReg); }
	ubyte modRmByte() { return encodeModRegRmByte(ModRmMod(memAddrType_to_mod[type]), cast(Register)0, Register.SP); }
	ubyte sibByte() { return encodeSibByte(scale, indexReg, baseReg); }
	bool hasDisp32() { return memAddrType_to_dispType[type] == 1; }
	bool hasDisp8 () { return memAddrType_to_dispType[type] == 2; }

	string toString() {
		final switch(type) {
			case MemAddrType.disp32: return format("[0x%x]", disp32);
			case MemAddrType.indexDisp32: return format("[(%s*%s) + 0x%x]", indexReg, scale.value, disp32);
			case MemAddrType.base: return format("[%s]", baseReg);
			case MemAddrType.baseDisp32: return format("[%s + 0x%x]", baseReg, disp32);
			case MemAddrType.baseIndex: return format("[%s + (%s*%s)]", baseReg, indexReg, scale.value);
			case MemAddrType.baseIndexDisp32: return format("[%s + (%s*%s) + 0x%x]", baseReg, indexReg, scale.value, disp32);
			case MemAddrType.baseDisp8: return format("[0x%x]", disp8);
			case MemAddrType.baseIndexDisp8: return format("[(%s*%s) + 0x%x]", indexReg, scale.value, disp8);
		}
	}
}

MemAddress memAddrDisp32(uint disp32) {
	return MemAddress(MemAddrType.disp32, Register.SP, Register.BP, SibScale(), disp32); }
MemAddress memAddrIndexDisp32(Register indexReg, SibScale scale, uint disp32) {
	return MemAddress(MemAddrType.indexDisp32, indexReg, Register.BP, scale, disp32); }
MemAddress memAddrBase(Register baseReg) {
	return MemAddress(MemAddrType.base, Register.SP, baseReg); }
MemAddress memAddrBaseDisp32(Register baseReg, uint disp32) {
	return MemAddress(MemAddrType.baseDisp32, Register.SP, baseReg, SibScale(), disp32); }
MemAddress memAddrBaseIndex(Register baseReg, Register indexReg, SibScale scale) {
	return MemAddress(MemAddrType.baseIndex, indexReg, baseReg, scale); }
MemAddress memAddrBaseIndexDisp32(Register baseReg, Register indexReg, SibScale scale, uint disp32) {
	return MemAddress(MemAddrType.baseIndexDisp32, indexReg, baseReg, scale, disp32); }
MemAddress memAddrBaseDisp8(Register baseReg, ubyte disp8) {
	return MemAddress(MemAddrType.baseDisp8, Register.SP, baseReg, SibScale(), disp8); }
MemAddress memAddrBaseIndexDisp8(Register baseReg, Register indexReg, SibScale scale, ubyte disp8) {
	return MemAddress(MemAddrType.baseIndexDisp8, indexReg, baseReg, scale, disp8); }

// Sink defines put(T) for ubyte, ubyte[], Imm8, Imm16, Imm32, Imm64
struct CodeGen_x86_64(Sink)
{
	Sink sink;

	private void putRexByteChecked(ArgType argType)(ubyte bits, bool forceRex = false) {
		static if (argType == ArgType.QWORD)
			sink.put(REX_PREFIX | REX_W | bits);
		else
			if (bits || forceRex) sink.put(REX_PREFIX | bits);
	}
	private void putRexByte_RB(ArgType argType)(Register reg, Register rm) {
		putRexByteChecked!argType(regTo_Rex_R(reg) | regTo_Rex_B(rm));
	}
	private void putRexByte_B(ArgType argType)(Register rm) {
		putRexByteChecked!argType(regTo_Rex_B(rm), regNeedsRexPrefix!argType(rm));
	}
	private void putRexByte_RXB(ArgType argType)(Register r, Register x, Register b) {
		putRexByteChecked!argType(regTo_Rex_R(r) | regTo_Rex_X(x) | regTo_Rex_B(b), regNeedsRexPrefix!argType(r));
	}

	private void putInstrRegReg(ArgType argType)(ubyte opcode, Register dst_rm, Register src_reg) {
		static if (argType == ArgType.WORD) sink.put(LegacyPrefix.OPERAND_SIZE);// 16 bit operand prefix
		putRexByte_RB!argType(src_reg, dst_rm);                                         // REX
		sink.put(opcode);                                                       // Opcode
		sink.put(encodeModRegRmByte(ModRmMod(0b11), src_reg, dst_rm));          // ModR/M
	}
	private void putInstrRegImm(ArgType argType, I)(ubyte opcode, Register dst_rm, I src_imm) if (isAnyImm!I) {
		static assert(argType == I.argT, "Sizes of imm and reg must be equal");
		static if (argType == ArgType.WORD) sink.put(LegacyPrefix.OPERAND_SIZE);// 16 bit operand prefix
		putRexByte_B!argType(dst_rm);                                           // REX
		sink.put(opcode | (dst_rm & 0b0111));                                   // Opcode
		sink.put(src_imm);                                                      // Imm
	}
	private void putInstrRegMem(ArgType argType)(ubyte opcode, Register dst_r, MemAddress src_mem) {
		static if (argType == ArgType.WORD) sink.put(LegacyPrefix.OPERAND_SIZE);// 16 bit operand prefix
		putRexByte_RXB!argType(dst_r, src_mem.indexReg, src_mem.baseReg);       // REX
		sink.put(opcode);                                                       // Opcode
		sink.put(src_mem.modRmByte | (dst_r & 0b0111) << 3);                    // ModR/M
		sink.put(src_mem.sibByte);                                              // SIB
		if (src_mem.hasDisp32)
			sink.put(Imm32(src_mem.disp32));                                    // disp32
		else if (src_mem.hasDisp8)
			sink.put(src_mem.disp8);                                            // disp8
	}
	private void putInstrMemImm(ArgType argType, I)(ubyte opcode, MemAddress dst_mem, I src_imm) if (isAnyImm!I) {
		static assert( // allow special case of QwordPtr and Imm32
			argType == I.argT || (argType == ArgType.QWORD && I.argT == ArgType.DWORD),
			"Sizes of ptr and imm must be equal");
		static if (argType == ArgType.WORD) sink.put(LegacyPrefix.OPERAND_SIZE);   // 16 bit operand prefix
		putRexByte_RXB!argType(cast(Register)0, dst_mem.indexReg, dst_mem.baseReg); // REX
		sink.put(opcode);                                                       // Opcode
		sink.put(dst_mem.modRmByte);                                            // ModR/M
		sink.put(dst_mem.sibByte);                                              // SIB
		if (dst_mem.hasDisp32)
			sink.put(Imm32(dst_mem.disp32));                                    // disp32
		else if (dst_mem.hasDisp8)
			sink.put(dst_mem.disp8);                                            // disp8
		sink.put(src_imm);                                                      // Mem8/16/32 Imm8/16/32
	}

	void beginFunction() {
		push(Register.BP);
		movQword(Register.BP, Register.SP);
	}
	void endFunction() {
		pop(Register.BP);
		ret();
	}

	void movByte(Register dst_rm, Register src_reg) { putInstrRegReg!(ArgType.BYTE) (0x88, dst_rm, src_reg); }
	void movWord(Register dst_rm, Register src_reg) { putInstrRegReg!(ArgType.WORD) (0x89, dst_rm, src_reg); }
	void movDword(Register dst_rm, Register src_reg) { putInstrRegReg!(ArgType.DWORD)(0x89, dst_rm, src_reg); }
	void movQword(Register dst_rm, Register src_reg) { putInstrRegReg!(ArgType.QWORD)(0x89, dst_rm, src_reg); }

	void movByte(Register dst_rm, Imm8  src_imm) { putInstrRegImm!(ArgType.BYTE)(0xB0, dst_rm, src_imm); }
	void movWord(Register dst_rm, Imm16 src_imm) { putInstrRegImm!(ArgType.WORD)(0xB8, dst_rm, src_imm); }
	void movDword(Register dst_rm, Imm32 src_imm) { putInstrRegImm!(ArgType.DWORD)(0xB8, dst_rm, src_imm); }
	void movQword(Register dst_rm, Imm64 src_imm) { putInstrRegImm!(ArgType.QWORD)(0xB8, dst_rm, src_imm); }

	void movByte(Register dst_reg, MemAddress src_rm) { putInstrRegMem!(ArgType.BYTE)(0x8A, dst_reg, src_rm); }
	void movWord(Register dst_reg, MemAddress src_rm) { putInstrRegMem!(ArgType.WORD)(0x8B, dst_reg, src_rm); }
	void movDword(Register dst_reg, MemAddress src_rm) { putInstrRegMem!(ArgType.DWORD)(0x8B, dst_reg, src_rm); }
	void movQword(Register dst_reg, MemAddress src_rm) { putInstrRegMem!(ArgType.QWORD)(0x8B, dst_reg, src_rm); }

	void movByte(MemAddress dst_rm, Register src_reg) { putInstrRegMem!(ArgType.BYTE)(0x88, src_reg, dst_rm); }
	void movWord(MemAddress dst_rm, Register src_reg) { putInstrRegMem!(ArgType.WORD)(0x89, src_reg, dst_rm); }
	void movDword(MemAddress dst_rm, Register src_reg) { putInstrRegMem!(ArgType.DWORD)(0x89, src_reg, dst_rm); }
	void movQword(MemAddress dst_rm, Register src_reg) { putInstrRegMem!(ArgType.QWORD)(0x89, src_reg, dst_rm); }

	void movByte(MemAddress dst_rm, Imm8  src_imm) { putInstrMemImm!(ArgType.BYTE)(0xC6, dst_rm, src_imm); }
	void movWord(MemAddress dst_rm, Imm16 src_imm) { putInstrMemImm!(ArgType.WORD)(0xC7, dst_rm, src_imm); }
	void movDword(MemAddress dst_rm, Imm32 src_imm) { putInstrMemImm!(ArgType.DWORD)(0xC7, dst_rm, src_imm); }
	void movQword(MemAddress dst_rm, Imm32 src_imm) { putInstrMemImm!(ArgType.QWORD)(0xC7, dst_rm, src_imm); }

	void ret() { sink.put(0xC3); }
	//void ret(uint retValue) { sink.put(0xC3); }
	void nop() { sink.put(0x90); }

	void push(Register reg) {
		if (reg > Register.DI) sink.put(0x41); // REX prefix
		sink.put(0x50 | (reg & 0b0111));     // Opcode
	}
	void push(Imm8 imm8) { // 32 64
		sink.put(0x6A);
		sink.put(imm8);
	}
	void push(Imm16 imm8) { // 32 64
		sink.put(0x6A);
		sink.put(imm8);
	}
	void pop(Register reg) { // 32 64
		if (reg > Register.DI) sink.put(0x41); // REX prefix
		sink.put(0x58 | reg); // opcode
	}
	void int3() { // 32 64
		sink.put(0xCC);
	}
}