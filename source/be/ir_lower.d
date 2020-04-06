/// Copyright: Copyright (c) 2017-2020 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module be.ir_lower;

import std.stdio;
import all;


void pass_ir_lower(CompilationContext* c, ModuleDeclNode* mod, FunctionDeclNode* func)
{
	FuncPassIr[] passes = [&func_pass_lower_abi_win64, &func_pass_lower_aggregates, &func_pass_lower_gep];
	IrBuilder builder;

	IrFunction* irData = c.getAst!IrFunction(func.backendData.irData);
	func.backendData.loweredIrData = c.appendAst!IrFunction;
	IrFunction* loweredIrData = c.getAst!IrFunction(func.backendData.loweredIrData);
	*loweredIrData = *irData; // copy

	builder.beginDup(loweredIrData, c);
	foreach (FuncPassIr pass; passes)
	{
		pass(c, loweredIrData, builder);
		if (c.validateIr)
			validateIrFunction(c, loweredIrData);
		if (c.printIrLowerEach && c.printDumpOf(func)) dumpFunction(c, loweredIrData, "IR lowering each");
	}
	if (!c.printIrLowerEach && c.printIrLower && c.printDumpOf(func)) dumpFunction(c, loweredIrData, "IR lowering all");
	builder.finalizeIr;
}

bool isPassByValue(IrIndex type, CompilationContext* c) {
	if (type.isTypeStruct) {
		IrTypeStruct* structRes = &c.types.get!IrTypeStruct(type);
		switch(structRes.size) {
			case 1: return true;
			case 2: return true;
			case 4: return true;
			case 8: return true;
			default: return false;
		}
	}
	return true;
}

void func_pass_lower_abi_win64(CompilationContext* c, IrFunction* ir, ref IrBuilder builder)
{
	//writefln("lower_abi %s", builder.context.idString(ir.backendData.name));
	// buffer for call/instruction arguments
	enum MAX_ARGS = 255;
	IrIndex[MAX_ARGS] argBuffer = void;

	// Handle ABI
	IrTypeFunction* irFuncType = &c.types.get!IrTypeFunction(ir.type);
	uint numHiddenParams = 0;
	IrIndex hiddenParameter;

	if (irFuncType.numResults == 0)
	{
		// keep original type
	}
	else if (irFuncType.numResults == 1)
	{
		IrIndex resType = irFuncType.resultTypes[0];
		if (resType.isPassByValue(c))
		{
			// keep original type
		}
		else
		{
			numHiddenParams = 1;
			IrIndex[] oldParams = irFuncType.parameterTypes;
			// create new type
			// dont modify the type
			IrIndex irType = c.types.appendFuncSignature(1, irFuncType.numParameters + 1, irFuncType.callConv);
			irFuncType = &c.types.get!IrTypeFunction(irType);
			// copy original parameters
			irFuncType.parameterTypes[1..$] = oldParams;

			IrIndex retType = c.types.appendPtr(resType);
			// set hidden parameter and return type
			irFuncType.parameterTypes[0] = retType;
			irFuncType.resultTypes[0] = retType;

			// Add hidden parameter(s) to first block
			ExtraInstrArgs extra = { type : retType };
			InstrWithResult param = builder.emitInstr!(IrOpcode.parameter)(extra);
			ir.get!IrInstr_parameter(param.instruction).index(ir) = -1; // to offset += 1 in parameter handling
			builder.prependBlockInstr(ir.entryBasicBlock, param.instruction);
			hiddenParameter = param.result;
		}
	}
	else
	{
		c.internal_error("%s results is not implemented", irFuncType.numResults);
	}

	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			switch(instrHeader.op)
			{
				case IrOpcode.parameter:
					IrInstr_parameter* param = ir.get!IrInstr_parameter(instrIndex);
					if (numHiddenParams == 1) param.index(ir) += 1;
					uint paramIndex = param.index(ir);

					bool isInPhysReg = paramIndex < ir.backendData.getCallConv(c).paramsInRegs.length;

					IrIndex type = ir.getVirtReg(instrHeader.result(ir)).type;
					if (isInPhysReg)
					{
						IrIndex paramReg = ir.backendData.getCallConv(c).paramsInRegs[paramIndex];
						if (type.isPassByValue(c))
						{
							// this branch is also executed for hidden ptr parameter

							paramReg.physRegSize = typeToRegSize(type, c);
							ExtraInstrArgs extra = { result : instrHeader.result(ir) };
							auto moveInstr = builder.emitInstr!(IrOpcode.move)(extra, paramReg).instruction;
							replaceInstruction(ir, instrIndex, moveInstr);
						}
						else
						{
							type = c.types.appendPtr(type);
							//irFuncType.parameterTypes[paramIndex] = type; // dont modify the type

							paramReg.physRegSize = typeToRegSize(type, c);
							ExtraInstrArgs extra1 = { type : type };
							auto moveInstr = builder.emitInstr!(IrOpcode.move)(extra1, paramReg);
							replaceInstruction(ir, instrIndex, moveInstr.instruction);

							ExtraInstrArgs extra2 = { result : instrHeader.result(ir) };
							IrIndex loadInstr = builder.emitInstr!(IrOpcode.load_aggregate)(extra2, moveInstr.result).instruction;
							ir.getInstr(loadInstr).isUniqueLoad = true;
							builder.insertAfterInstr(moveInstr.instruction, loadInstr);
						}
					}
					else
					{
						if (type.isPassByValue(c)) {
							//writefln("parameter %s stack val", paramIndex);
							IrIndex slot = ir.backendData.stackLayout.addStackItem(c, type, StackSlotKind.parameter, cast(ushort)paramIndex);
							// is directly in stack
							IrArgSize argSize = getTypeArgSize(type, c);
							ExtraInstrArgs extra = { argSize : argSize, result : instrHeader.result(ir) };
							IrIndex loadInstr = builder.emitInstr!(IrOpcode.load)(extra, slot).instruction;
							replaceInstruction(ir, instrIndex, loadInstr);
						} else {
							// stack contains pointer to data
							//writefln("parameter %s stack ptr", paramIndex);
							//convertAggregateVregToPointer(instrHeader.result(ir), ir, builder);
							type = c.types.appendPtr(type);
							//irFuncType.parameterTypes[paramIndex] = type; // dont modify the type
							IrIndex slot = ir.backendData.stackLayout.addStackItem(c, type, StackSlotKind.parameter, cast(ushort)paramIndex);
							IrArgSize argSize = getTypeArgSize(type, c);
							ExtraInstrArgs extra = { argSize : argSize, type : type };
							InstrWithResult loadInstr = builder.emitInstr!(IrOpcode.load)(extra, slot);
							// remove parameter instruction
							replaceInstruction(ir, instrIndex, loadInstr.instruction);

							// load aggregate
							ExtraInstrArgs extra2 = { result : instrHeader.result(ir) };
							InstrWithResult loadInstr2 = builder.emitInstr!(IrOpcode.load_aggregate)(extra2, loadInstr.result);
							ir.getInstr(loadInstr2.instruction).isUniqueLoad = true;
							builder.insertAfterInstr(loadInstr.instruction, loadInstr2.instruction);
						}
					}
					break;

				case IrOpcode.call:
					ir.backendData.stackLayout.numCalls += 1;

					IrIndex callee = instrHeader.arg(ir, 0);
					IrIndex calleeTypeIndex = ir.getValueType(c, callee);
					if (calleeTypeIndex.isTypePointer)
						calleeTypeIndex = c.types.getPointerBaseType(calleeTypeIndex);
					IrTypeFunction* calleeType = &c.types.get!IrTypeFunction(calleeTypeIndex);

					CallConv* callConv = c.types.getCalleeCallConv(callee, ir, c);
					IrIndex[] args = instrHeader.args(ir)[1..$]; // exclude callee
					IrIndex originalResult;
					IrIndex hiddenPtr;
					bool hasHiddenPtr = false;

					// allocate stack slot for big return value
					if (calleeType.numResults == 1)
					{
						originalResult = instrHeader.result(ir);
						IrIndex resType = calleeType.resultTypes[0];
						if (!resType.isPassByValue(c))
						{
							// reuse result slot of instruction as first argument
							instrHeader._payloadOffset -= 1;
							instrHeader.hasResult = false;
							instrHeader.numArgs += 1;

							args = instrHeader.args(ir)[1..$];
							// move callee in first arg
							instrHeader.arg(ir, 0) = callee;
							// place return arg slot in second arg
							hiddenPtr = ir.backendData.stackLayout.addStackItem(c, resType, StackSlotKind.argument, 0);
							args[0] = hiddenPtr;
							hasHiddenPtr = true;

							//convertAggregateVregToPointer(originalResult, ir, builder, args[0]);
							//builder.redirectVregUsersTo(originalResult, args[0]);
						}
					}

					enum STACK_ITEM_SIZE = 8;
					size_t numArgs = args.length;
					size_t numParamsInRegs = callConv.paramsInRegs.length;
					// how many bytes are allocated on the stack before func call
					size_t stackReserve = max(numArgs, numParamsInRegs) * STACK_ITEM_SIZE;
					IrIndex stackPtrReg = callConv.stackPointer;

					// Copy args to stack if necessary (big structs or run out of regs)
					foreach (size_t i; cast(size_t)hasHiddenPtr..args.length)
					{
						IrIndex arg = args[i];
						removeUser(c, ir, instrIndex, arg);

						IrIndex type = calleeType.parameterTypes[i-cast(size_t)hasHiddenPtr];

						if (type.isPassByValue(c)) {
							arg = simplifyConstant(arg, c);
							args[i] = arg;
						} else {
							//allocate stack slot, store value there and use slot pointer as argument
							args[i] = ir.backendData.stackLayout.addStackItem(c, type, StackSlotKind.argument, 0);
							IrIndex instr = builder.emitInstr!(IrOpcode.store)(ExtraInstrArgs(), args[i], arg);
							builder.insertBeforeInstr(instrIndex, instr);
						}
					}

					// align stack and push args that didn't fit into registers (register size args)
					if (numArgs > numParamsInRegs)
					{
						if (numArgs % 2 == 1)
						{	// align stack to 16 bytes
							stackReserve += STACK_ITEM_SIZE;
							IrIndex paddingSize = c.constants.add(STACK_ITEM_SIZE, IsSigned.no);
							auto growStackInstr = builder.emitInstr!(IrOpcode.grow_stack)(ExtraInstrArgs(), paddingSize);
							builder.insertBeforeInstr(instrIndex, growStackInstr);
						}

						// push args to stack
						foreach_reverse (IrIndex arg; args[numParamsInRegs..numArgs])
						{
							auto pushInstr = builder.emitInstr!(IrOpcode.push)(ExtraInstrArgs(), arg);
							builder.insertBeforeInstr(instrIndex, pushInstr);
						}
					}

					// move args to registers
					size_t numPhysRegs = min(numParamsInRegs, numArgs);
					foreach (i, IrIndex arg; args[0..numPhysRegs])
					{
						IrIndex type = ir.getValueType(c, arg);
						IrIndex argRegister = callConv.paramsInRegs[i];
						argRegister.physRegSize = typeToRegSize(type, c);
						args[i] = argRegister;
						ExtraInstrArgs extra = { result : argRegister };
						auto moveInstr = builder.emitInstr!(IrOpcode.move)(extra, arg).instruction;
						builder.insertBeforeInstr(instrIndex, moveInstr);
					}

					{	// Allocate shadow space for 4 physical registers
						IrIndex const_32 = c.constants.add(32, IsSigned.no);
						auto growStackInstr = builder.emitInstr!(IrOpcode.grow_stack)(ExtraInstrArgs(), const_32);
						builder.insertBeforeInstr(instrIndex, growStackInstr);
					}

					{
						instrHeader.numArgs = cast(ubyte)(numPhysRegs + 1); // include callee

						// Deallocate stack after call
						IrIndex conReservedBytes = c.constants.add(stackReserve, IsSigned.no);
						auto shrinkStackInstr = builder.emitInstr!(IrOpcode.shrink_stack)(ExtraInstrArgs(), conReservedBytes);
						builder.insertAfterInstr(instrIndex, shrinkStackInstr);

						// for calls that return in register
						if (instrHeader.hasResult) {
							// mov result to virt reg
							IrIndex returnReg = callConv.returnReg;
							returnReg.physRegSize = typeToIrArgSize(ir.getVirtReg(instrHeader.result(ir)).type, c);
							ExtraInstrArgs extra = { result : instrHeader.result(ir) };
							auto moveInstr = builder.emitInstr!(IrOpcode.move)(extra, returnReg).instruction;
							//builder.redirectVregDefinitionTo(instrHeader.result(ir), moveInstr);
							builder.insertAfterInstr(shrinkStackInstr, moveInstr);
							instrHeader.result(ir) = returnReg;
						} else if (hasHiddenPtr) {
							ExtraInstrArgs extra = { result : originalResult };
							IrIndex loadInstr = builder.emitInstr!(IrOpcode.load_aggregate)(extra, hiddenPtr).instruction;
							ir.getInstr(loadInstr).isUniqueLoad = true;
							builder.insertAfterInstr(shrinkStackInstr, loadInstr);
						}
					}
					break;

				case IrOpcode.ret_val:
					removeUser(c, ir, instrIndex, instrHeader.arg(ir, 0));
					if (numHiddenParams == 1) {
						// store struct into pointer, then return pointer
						IrIndex value = instrHeader.arg(ir, 0);
						IrIndex instr = builder.emitInstr!(IrOpcode.store)(ExtraInstrArgs(), hiddenParameter, value);
						builder.insertBeforeInstr(instrIndex, instr);
						instrHeader.arg(ir, 0) = hiddenParameter;
						IrIndex result = ir.backendData.getCallConv(c).returnReg;
						ExtraInstrArgs extra = { result : result };
						IrIndex copyInstr = builder.emitInstr!(IrOpcode.move)(extra, hiddenParameter).instruction;
						builder.insertBeforeInstr(instrIndex, copyInstr);
					} else {
						IrIndex value = simplifyConstant(instrHeader.arg(ir, 0), c);
						IrIndex result = ir.backendData.getCallConv(c).returnReg;
						IrIndex type = irFuncType.resultTypes[0];
						result.physRegSize = typeToRegSize(type, c);
						ExtraInstrArgs extra = { result : result };
						IrIndex copyInstr = builder.emitInstr!(IrOpcode.move)(extra, value).instruction;
						builder.insertBeforeInstr(instrIndex, copyInstr);
					}
					// rewrite ret_val as ret in-place
					instrHeader.op = IrOpcode.ret;
					instrHeader.numArgs = 0;
					break;

				default:
					//c.internal_error("IR lower unimplemented IR instr %s", cast(IrOpcode)instrHeader.op);
					break;
			}
		}
	}
}

/// Converts complex constants fitting in a single register into an integer constant
IrIndex simplifyConstant(IrIndex index, CompilationContext* c)
{
	union U {
		ulong bufferValue;
		ubyte[8] buffer;
	}
	U data;
	uint typeSize;
	if (index.isConstantZero)
	{
		typeSize = c.types.typeSize(index.constantZeroType);
	}
	else if (index.isConstantAggregate)
	{
		IrAggregateConstant* con = &c.constants.getAggregate(index);
		typeSize = c.types.typeSize(con.type);
	}
	else
	{
		return index;
	}

	constantToMem(data.buffer[0..typeSize], index, c);
	return c.constants.add(data.bufferValue, IsSigned.no, sizeToIrArgSize(typeSize, c));
}

IrIndex genAddressOffset(IrIndex ptr, uint offset, IrIndex ptrType, IrIndex beforeInstr, ref IrBuilder builder) {
	if (offset == 0) {
		ExtraInstrArgs extra = { type : ptrType };
		InstrWithResult movInstr = builder.emitInstrBefore!(IrOpcode.move)(beforeInstr, extra, ptr);
		return movInstr.result;
	} else {
		IrIndex offsetIndex = builder.context.constants.add(offset, IsSigned.no);
		ExtraInstrArgs extra = { type : ptrType };
		InstrWithResult addressInstr = builder.emitInstrBefore!(IrOpcode.add)(beforeInstr, extra, ptr, offsetIndex);
		return addressInstr.result;
	}
}

IrIndex genCopy(IrIndex dst, IrIndex src, IrIndex beforeInstr, ref IrBuilder builder) {
	if (src.isSomeConstant)
		return builder.emitInstrBefore!(IrOpcode.store)(beforeInstr, ExtraInstrArgs(), dst, src);
	else
		return builder.emitInstrBefore!(IrOpcode.copy)(beforeInstr, ExtraInstrArgs(), dst, src);
}

IrIndex genLoad(IrIndex ptr, uint offset, IrIndex ptrType, IrIndex beforeInstr, ref IrBuilder builder) {
	ptr = genAddressOffset(ptr, offset, ptrType, beforeInstr, builder);
	IrIndex valType = builder.context.types.getPointerBaseType(ptrType);
	IrArgSize argSize = typeToIrArgSize(valType, builder.context);
	ExtraInstrArgs extra = { type : valType, argSize : argSize };
	auto instr = builder.emitInstrBefore!(IrOpcode.load)(beforeInstr, extra, ptr);
	return instr.result;
}

struct LowerVreg
{
	IrIndex redirectTo;
}

void func_pass_lower_aggregates(CompilationContext* c, IrFunction* ir, ref IrBuilder builder)
{
	//writefln("lower_aggregates %s", c.idString(ir.backendData.name));

	// buffer for call/instruction arguments
	enum MAX_ARGS = 255;
	IrIndex[MAX_ARGS] argBuffer = void;

	LowerVreg[] vregInfos = makeParallelArray!LowerVreg(c, ir.numVirtualRegisters);

	foreach (IrIndex vregIndex, ref IrVirtualRegister vreg; ir.virtualRegsiters)
	{
		if (vreg.type.isTypeStruct || vreg.type.isTypeArray)
		{
			//writefln("- vreg %s", vregIndex);

			IrInstrHeader* definition = ir.getInstr(vreg.definition);
			if (definition.op == IrOpcode.load_aggregate)
			{
				// we can omit stack allocation and reuse source memory
				if (definition.isUniqueLoad)
				{
					vregInfos[vregIndex.storageUintIndex].redirectTo = definition.arg(ir, 0);
					removeInstruction(ir, vreg.definition);
				}
			}
		}
	}

	// transforms instructions
	// gathers all registers to be promoted to pointer
	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		foreach(IrIndex phiIndex, ref IrPhi phi; block.phis(ir))
		{
			IrIndex type = ir.getVirtReg(phi.result).type;
			if (!type.isPassByValue(c)) {
				//writefln("- phi %s", phiIndex);
			}
			foreach(size_t arg_i, ref IrIndex phiArg; phi.args(ir))
			{
			}
		}

		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			switch(instrHeader.op)
			{
				case IrOpcode.store:
					IrIndex ptr = instrHeader.arg(ir, 0);
					IrIndex val = instrHeader.arg(ir, 1);
					//writefln("- store %s %s %s", instrIndex, ptr, val);
					IrIndex ptrType = ir.getValueType(c, ptr);
					IrIndex valType = ir.getValueType(c, val);

					// value will be replaced with pointer, replace store with copy
					if (!valType.isPassByValue(c) && !val.isSomeConstant)
					{
						instrHeader.op = IrOpcode.copy;
					}
					break;

				case IrOpcode.load_aggregate:
					//writefln("- load_aggregate %s", instrIndex);
					IrIndex ptr = instrHeader.arg(ir, 0);
					IrIndex ptrType = ir.getValueType(c, ptr);
					IrIndex base = c.types.getPointerBaseType(ptrType);

					if (base.isPassByValue(c))
					{
						IrArgSize argSize = typeToIrArgSize(base, c);
						ExtraInstrArgs extra = { result : instrHeader.result(ir), argSize : argSize };
						builder.emitInstrBefore!(IrOpcode.load)(instrIndex, extra, ptr);
					}
					else
					{
						IrIndex slot = ir.backendData.stackLayout.addStackItem(c, base, StackSlotKind.local, 0);
						genCopy(slot, instrHeader.arg(ir, 0), instrIndex, builder);

						vregInfos[instrHeader.result(ir).storageUintIndex].redirectTo = slot;
					}
					removeInstruction(ir, instrIndex);
					break;

				case IrOpcode.create_aggregate:
					//writefln("- create_aggregate %s", instrIndex);
					IrIndex type = ir.getVirtReg(instrHeader.result(ir)).type;

					if (!type.isPassByValue(c)) {
						IrTypeStruct* structType = &c.types.get!IrTypeStruct(type);
						IrIndex slot = ir.backendData.stackLayout.addStackItem(c, type, StackSlotKind.local, 0);
						vregInfos[instrHeader.result(ir).storageUintIndex].redirectTo = slot;

						IrIndex[] members = instrHeader.args(ir);
						c.assertf(members.length == structType.numMembers, "%s != %s", members.length, structType.numMembers);

						foreach (i, IrTypeStructMember member; structType.members)
						{
							IrIndex ptrType = c.types.appendPtr(member.type);
							IrIndex ptr = genAddressOffset(slot, member.offset, ptrType, instrIndex, builder);
							if (member.type.isPassByValue(c))
							{
								IrArgSize argSize = getTypeArgSize(member.type, c);
								ExtraInstrArgs extra = { argSize : argSize };
								builder.emitInstrBefore!(IrOpcode.store)(instrIndex, extra, ptr, members[i]);
							}
							else
							{
								builder.emitInstrBefore!(IrOpcode.copy)(instrIndex, ExtraInstrArgs(), ptr, members[i]);
							}
						}
						//convertAggregateVregToPointer(instrHeader.result(ir), ir, builder);
						removeInstruction(ir, instrIndex);
					}
					else
						createSmallAggregate(instrIndex, type, instrHeader, ir, builder);
					break;

				case IrOpcode.get_element:
					//writefln("- get_element %s", instrIndex);
					// instruction is reused
					IrIndex resultType = getValueType(instrHeader.result(ir), ir, c);
					instrHeader.op = IrOpcode.get_element_ptr_0;

					if (resultType.isPassByValue(c))
					{
						IrIndex loadResult = instrHeader.result(ir);
						IrIndex ptrType = c.types.appendPtr(resultType);
						IrIndex gepResult = builder.addVirtualRegister(instrIndex, ptrType);
						instrHeader.result(ir) = gepResult;

						ExtraInstrArgs extra2 = { argSize : getTypeArgSize(resultType, c), result : loadResult };
						IrIndex loadInstr = builder.emitInstr!(IrOpcode.load)(extra2, gepResult).instruction;
						builder.insertAfterInstr(instrIndex, loadInstr);
					}
					break;
				case IrOpcode.insert_element:
					//writefln("- insert_element %s", instrIndex);
					break;

				default:
					//c.internal_error("IR lower unimplemented IR instr %s", cast(IrOpcode)instrHeader.op);
					break;
			}
		}
	}

	foreach(i, info; vregInfos)
	{
		if (info.redirectTo.isDefined)
		{
			builder.redirectVregUsersTo(IrIndex(cast(uint)i, IrValueKind.virtualRegister), info.redirectTo);
		}
	}
}

// pack values and constants into a register via `shift` and `binary or` instructions
void createSmallAggregate(IrIndex instrIndex, IrIndex type, ref IrInstrHeader instrHeader, IrFunction* ir, ref IrBuilder builder)
{
	CompilationContext* c = builder.context;

	uint targetTypeSize = c.types.typeSize(type);
	IrArgSize argSize = sizeToIrArgSize(targetTypeSize, c);
	c.assertf(instrHeader.numArgs <= 8, "too much args %s", instrHeader.numArgs);
	ulong constant = 0;
	// how many non-constants are prepared in argBuffer
	uint numBufferedValues = 0;

	IrIndex[2] argBuffer;

	void insertNonConstant(IrIndex value, uint bit_offset, uint size)
	{
		if (size < targetTypeSize) {
			ExtraInstrArgs extra = { argSize : argSize, type : type };
			switch(size) { // zero extend 8 and 16 bit args to 32bit
				case 1: value = builder.emitInstrBefore!(IrOpcode.zext)(instrIndex, extra, value).result; break;
				case 2: value = builder.emitInstrBefore!(IrOpcode.zext)(instrIndex, extra, value).result; break;
				default: break;
			}
		}

		// shift
		if (bit_offset == 0)
			argBuffer[numBufferedValues] = value;
		else
		{
			IrIndex rightArg = c.constants.add(bit_offset, IsSigned.no);
			ExtraInstrArgs extra1 = { argSize : argSize, type : type };
			IrIndex shiftRes = builder.emitInstrBefore!(IrOpcode.shl)(instrIndex, extra1, value, rightArg).result;
			argBuffer[numBufferedValues] = shiftRes;
		}
		++numBufferedValues;

		if (numBufferedValues == 2)
		{
			// or
			ExtraInstrArgs extra2 = { argSize : argSize, type : type };
			argBuffer[0] = builder.emitInstrBefore!(IrOpcode.or)(instrIndex, extra2, argBuffer[0], argBuffer[1]).result;
			numBufferedValues = 1;
		}
	}

	void insertAt(IrIndex value, uint offset, uint size)
	{
		if (value.isConstant) {
			constant |= c.constants.get(value).i64 << (offset * 8);
		} else {
			insertNonConstant(value, offset * 8, size);
		}
	}

	switch(type.typeKind) with(IrTypeKind) {
		case struct_t:
			IrTypeStruct* structType = &c.types.get!IrTypeStruct(type);
			IrIndex[] args = instrHeader.args(ir);
			foreach_reverse (i, IrTypeStructMember member; structType.members)
			{
				uint memberSize = c.types.typeSize(member.type);
				insertAt(args[i], member.offset, memberSize);
			}
			break;
		case array:
			IrTypeArray* arrayType = &c.types.get!IrTypeArray(type);
			uint elemSize = c.types.typeSize(arrayType.elemType);
			IrIndex[] args = instrHeader.args(ir);
			foreach_reverse (i; 0..arrayType.size)
			{
				insertAt(args[i], i * elemSize, elemSize);
			}
			break;
		default: assert(false);
	}

	IrIndex constIndex = c.constants.add(constant, IsSigned.no, argSize);
	IrIndex result;
	if (numBufferedValues == 1)
	{
		if (constant == 0)
		{
			result = argBuffer[0];
		}
		else
		{
			bool isBigConstant = c.constants.get(constIndex).payloadSize(constIndex) == IrArgSize.size64;

			if (isBigConstant)
			{
				// copy to temp register
				ExtraInstrArgs extra = { argSize : argSize, type : type };
				constIndex = builder.emitInstrBefore!(IrOpcode.move)(instrIndex, extra, constIndex).result;
			}

			ExtraInstrArgs extra3 = { argSize : argSize, type : type };
			result = builder.emitInstrBefore!(IrOpcode.or)(instrIndex, extra3, argBuffer[0], constIndex).result;
		}
	}
	else
	{
		result = constIndex;
	}
	builder.redirectVregUsersTo(instrHeader.result(ir), result);
	removeInstruction(ir, instrIndex);
}

void func_pass_lower_gep(CompilationContext* context, IrFunction* ir, ref IrBuilder builder)
{
	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructions(ir))
		{
			switch(cast(IrOpcode)instrHeader.op) with(IrOpcode)
			{
				case get_element_ptr, get_element_ptr_0:
					lowerGEP(context, builder, instrIndex, instrHeader);
					break;
				default: break;
			}
		}
	}
}

// TODO some typecasts are needed for correct typing
void lowerGEP(CompilationContext* context, ref IrBuilder builder, IrIndex instrIndex, ref IrInstrHeader instrHeader)
{
	IrIndex buildOffset(IrIndex basePtr, long offsetVal, IrIndex resultType) {
		if (offsetVal == 0) {
			// Shortcut for 0-th index
			IrIndex basePtrType = getValueType(basePtr, builder.ir, context);
			// TODO: prefer proper typing for now, until IR lowering is implemented
			if (basePtrType == resultType) return basePtr;

			ExtraInstrArgs extra = { type : resultType };
			InstrWithResult instr = builder.emitInstr!(IrOpcode.conv)(extra, basePtr);
			builder.insertBeforeInstr(instrIndex, instr.instruction);
			return instr.result;
		} else {
			IrIndex offset = context.constants.add(offsetVal, IsSigned.yes);

			ExtraInstrArgs extra = { type : resultType };
			InstrWithResult addressInstr = builder.emitInstr!(IrOpcode.add)(extra, basePtr, offset);
			builder.insertBeforeInstr(instrIndex, addressInstr.instruction);

			return addressInstr.result;
		}
	}

	IrIndex buildIndex(IrIndex basePtr, IrIndex index, uint elemSize, IrIndex resultType)
	{
		IrIndex scale = context.constants.add(elemSize, IsSigned.no);
		IrIndex indexVal = index;

		if (elemSize > 1) {
			ExtraInstrArgs extra1 = { type : makeBasicTypeIndex(IrValueType.i64) };
			InstrWithResult offsetInstr = builder.emitInstr!(IrOpcode.umul)(extra1, index, scale);
			builder.insertBeforeInstr(instrIndex, offsetInstr.instruction);
			indexVal = offsetInstr.result;
		}

		ExtraInstrArgs extra2 = { type : resultType };
		InstrWithResult addressInstr = builder.emitInstr!(IrOpcode.add)(extra2, basePtr, indexVal);
		builder.insertBeforeInstr(instrIndex, addressInstr.instruction);

		return addressInstr.result;
	}

	IrIndex aggrPtr = instrHeader.arg(builder.ir, 0); // aggregate ptr
	IrIndex aggrPtrType = getValueType(aggrPtr, builder.ir, context);

	context.assertf(aggrPtrType.isTypePointer,
		"First argument to GEP instruction must be pointer, not %s", aggrPtr.typeKind);

	IrIndex aggrType = context.types.getPointerBaseType(aggrPtrType);
	uint aggrSize = context.types.typeSize(aggrType);

	IrIndex[] args;

	// get_element_ptr_0 first index is zero, hence no op
	if (cast(IrOpcode)instrHeader.op == IrOpcode.get_element_ptr)
	{
		IrIndex firstIndex = instrHeader.arg(builder.ir, 1);

		if (firstIndex.isSimpleConstant) {
			long indexVal = context.constants.get(firstIndex).i64;
			long offset = indexVal * aggrSize;
			aggrPtr = buildOffset(aggrPtr, offset, aggrPtrType);
		} else {
			aggrPtr = buildIndex(aggrPtr, firstIndex, aggrSize, aggrPtrType);
		}

		args = instrHeader.args(builder.ir)[2..$]; // 0 is ptr, 1 is first index
	}
	else
	{
		args = instrHeader.args(builder.ir)[1..$]; // 0 is ptr
	}

	foreach(IrIndex memberIndex; args)
	{
		final switch(aggrType.typeKind)
		{
			case IrTypeKind.basic:
				context.internal_error("Cannot index basic type %s", aggrType.typeKind);
				break;

			case IrTypeKind.pointer:
				context.internal_error("Cannot index pointer with GEP instruction, use load first");
				break;

			case IrTypeKind.array:
				IrIndex elemType = context.types.getArrayElementType(aggrType);
				IrIndex elemPtrType = context.types.appendPtr(elemType);
				uint elemSize = context.types.typeSize(elemType);

				if (memberIndex.isSimpleConstant) {
					long indexVal = context.constants.get(memberIndex).i64;
					long offset = indexVal * elemSize;
					aggrPtr = buildOffset(aggrPtr, offset, elemPtrType);
				} else {
					aggrPtr = buildIndex(aggrPtr, memberIndex, elemSize, elemPtrType);
				}

				aggrType = elemType;
				break;

			case IrTypeKind.struct_t:
				context.assertf(memberIndex.isSimpleConstant, "Structs can only be indexed with constants, not with %s", memberIndex);

				long memberIndexVal = context.constants.get(memberIndex).i64;
				IrTypeStructMember[] members = context.types.get!IrTypeStruct(aggrType).members;

				context.assertf(memberIndexVal < members.length,
					"Indexing member %s of %s-member struct",
					memberIndexVal, members.length);

				IrTypeStructMember member = members[memberIndexVal];
				IrIndex memberPtrType = context.types.appendPtr(member.type);

				aggrPtr = buildOffset(aggrPtr, member.offset, memberPtrType);
				aggrType = member.type;
				break;

			case IrTypeKind.func_t:
				context.internal_error("Cannot index function type");
				break;
		}
	}

	builder.redirectVregUsersTo(instrHeader.result(builder.ir), aggrPtr);
	removeInstruction(builder.ir, instrIndex);
}
