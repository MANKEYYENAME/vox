/**
Copyright: Copyright (c) 2017-2019 Andrey Penechko.
License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Andrey Penechko.
*/

module be.optimize;

import std.stdio;
import all;

alias FuncPassIr = void function(CompilationContext*, IrFunction*, ref IrBuilder);
alias FuncPass = void function(CompilationContext*, IrFunction*);

void apply_lir_func_pass(CompilationContext* context, FuncPass pass)
{
	foreach (ref SourceFileInfo file; context.files.data)
	foreach (IrFunction* lir; file.mod.lirModule.functions) {
		pass(context, lir);
		if (context.validateIr)
			validateIrFunction(context, lir);
	}
}

void pass_optimize_ir(ref CompilationContext context, ref ModuleDeclNode mod, ref FunctionDeclNode func)
{
	if (func.isExternal) return;

	FuncPassIr[] passes = [&func_pass_invert_conditions, &func_pass_remove_dead_code];
	IrBuilder builder;

	IrFunction* irData = context.getAst!IrFunction(func.backendData.irData);
	builder.beginDup(irData, &context);
	foreach (FuncPassIr pass; passes) {
		pass(&context, irData, builder);
		if (context.validateIr)
			validateIrFunction(&context, irData);
		if (context.printIrOpt && context.printDumpOf(&func)) dumpFunction(&context, irData, "IR opt");
	}
	builder.finalizeIr;
}

void func_pass_invert_conditions(CompilationContext* context, IrFunction* ir, ref IrBuilder builder)
{
	ir.assignSequentialBlockIndices();

	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		if (!block.lastInstr.isDefined) continue;

		IrInstrHeader* instrHeader = ir.getInstr(block.lastInstr);
		ubyte invertedCond;

		switch(instrHeader.op) with(IrOpcode)
		{
			case branch_unary:
				invertedCond = invertUnaryCond(cast(IrUnaryCondition)instrHeader.cond);
				break;
			case branch_binary:
				invertedCond = invertBinaryCond(cast(IrBinaryCondition)instrHeader.cond);
				break;

			default: continue;
		}

		uint seqIndex0 = ir.getBlock(block.successors[0, ir]).seqIndex;
		uint seqIndex1 = ir.getBlock(block.successors[1, ir]).seqIndex;
		if (block.seqIndex + 1 == seqIndex0)
		{
			instrHeader.cond = invertedCond;
			IrIndex succIndex0 = block.successors[0, ir];
			IrIndex succIndex1 = block.successors[1, ir];
			block.successors[0, ir] = succIndex1;
			block.successors[1, ir] = succIndex0;
		}
	}
}

void func_pass_remove_dead_code(CompilationContext* context, IrFunction* ir, ref IrBuilder builder)
{
	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocksReverse)
	{
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructionsReverse(ir))
		{
			if (hasSideEffects(cast(IrOpcode)instrHeader.op)) continue;
			if (!instrHeader.hasResult) continue;

			context.assertf(instrHeader.result(ir).isVirtReg, "instruction result must be virt reg");
			if (ir.getVirtReg(instrHeader.result(ir)).users.length > 0) continue;

			// we found some dead instruction, remove it
			foreach(ref IrIndex arg; instrHeader.args(ir)) {
				removeUser(context, ir, instrIndex, arg);
			}
			removeInstruction(ir, instrIndex);
			//writefln("remove dead %s", instrIndex);
		}
	}
}

/*
void lir_func_pass_simplify(ref CompilationContext context, ref IrFunction ir)
{
	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocksReverse)
	{
		foreach(IrIndex instrIndex, ref IrInstrHeader instrHeader; block.instructionsReverse(ir))
		{
			switch(cast(Amd64Opcode)instrHeader.op) with(Amd64Opcode)
			{
				case mov:
					static assert(LirAmd64Instr_xor.sizeof == LirAmd64Instr_mov.sizeof);
					// replace 'mov reg, 0' with xor reg reg
					IrIndex dst = instrHeader.result;
					IrIndex src = instrHeader.args[0];
					if (src.isConstant && context.constants.get(src).i64 == 0)
					{

					}
				default: break;
			}
		}
	}
}
*/
void pass_optimize_lir(CompilationContext* context)
{
	apply_lir_func_pass(context, &pass_optimize_lir_func);
}

void pass_optimize_lir_func(CompilationContext* context, IrFunction* ir)
{
	ir.assignSequentialBlockIndices();

	foreach (IrIndex blockIndex, ref IrBasicBlock block; ir.blocks)
	{
		if (!block.lastInstr.isDefined) continue;

		IrInstrHeader* instrHeader = ir.getInstr(block.lastInstr);
		auto isJump = context.machineInfo.instrInfo[instrHeader.op].isJump;

		if (isJump)
		{
			uint seqIndex0 = ir.getBlock(block.successors[0, ir]).seqIndex;
			// successor is the next instruction after current block
			if (block.seqIndex + 1 == seqIndex0)
			{
				removeInstruction(ir, block.lastInstr);
			}
		}
	}
}
