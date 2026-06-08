using System;
using System.Collections.Generic;

namespace BPlus.Runtime;

public static class X64Encoder
{
    public static byte[] Encode(OpCode op, params Operand[] operands)
    {
        var bytes = new List<byte>();

        switch (op)
        {
            case OpCode.MOV_R64_IMM64:
            {
                if (operands.Length != 2) throw new ArgumentException("MOV_R64_IMM64 needs 2 operands");
                int reg = operands[0].Reg;
                if (reg < 0 || reg > 15) throw new ArgumentException($"Invalid register: {reg}");
                if (reg >= 8)
                    bytes.Add((byte)(0x48 + ((reg >> 3) & 1))); // REX.W + REX.B
                else
                    bytes.Add(0x48); // REX.W
                bytes.Add((byte)(0xB8 + (reg & 7)));
                byte[] imm = BitConverter.GetBytes((ulong)operands[1].Imm64);
                bytes.AddRange(imm);
                break;
            }

            case OpCode.MOV_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("MOV_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                if (dst < 0 || dst > 15 || src < 0 || src > 15) throw new ArgumentException("Invalid registers");
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2))); // REX.W + REX.B + REX.R
                bytes.Add(0x8B);
                byte modrm = (byte)((((dst & 7) << 3) | (src & 7)) | 0xC0); // mod=11
                bytes.Add(modrm);
                break;
            }

            case OpCode.MOV_R64_MEM:
            {
                if (operands.Length != 2) throw new ArgumentException("MOV_R64_MEM needs 2 operands");
                int reg = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                if (reg < 0 || reg > 15 || baseReg < 0 || baseReg > 15) throw new ArgumentException("Invalid registers");
                if (baseReg == 255) // RIP-relative
                {
                    int disp = operands[1].Disp;
                    bytes.Add((byte)(0x48 + ((reg >> 3) & 1)));
                    bytes.Add(0x8B);
                    bytes.Add((byte)(0x05 + ((reg & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int disp = operands[1].Disp;
                    int rexB = (baseReg >> 3) & 1;
                    int rexR = (reg >> 3) & 1;
                    bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                    bytes.Add(0x8B);
                    EncodeModrmSib(bytes, reg, baseReg, disp);
                }
                break;
            }

            case OpCode.MOV_R32_MEM:
            {
                // 32-bit MOV from memory (no REX.W) — zero-extends to 64 on x64
                if (operands.Length != 2) throw new ArgumentException("MOV_R32_MEM needs 2 operands");
                int reg = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                if (reg < 0 || reg > 15 || baseReg < 0 || baseReg > 15) throw new ArgumentException("Invalid registers");
                int disp = operands[1].Disp;
                int rexB = (baseReg >> 3) & 1;
                int rexR = (reg >> 3) & 1;
                byte rex = (byte)(rexB | (rexR << 2));
                if (rex != 0) bytes.Add((byte)(0x40 | rex));
                bytes.Add(0x8B);
                EncodeModrmSib(bytes, reg, baseReg, disp);
                break;
            }

            case OpCode.MOV_MEM_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("MOV_MEM_R64 needs 2 operands");
                int baseReg = operands[0].BaseReg;
                int src = operands[1].Reg;
                if (src < 0 || src > 15 || baseReg < 0 || baseReg > 15) throw new ArgumentException("Invalid registers");
                int disp = operands[0].Disp;
                int rexB = (baseReg >> 3) & 1;
                int rexR = (src >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x89);
                EncodeModrmSib(bytes, src, baseReg, disp);
                break;
            }

            case OpCode.ADD_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("ADD_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2))); // REX.W
                bytes.Add(0x03);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.ADD_R64_IMM32:
            {
                if (operands.Length != 2) throw new ArgumentException("ADD_R64_IMM32 needs 2 operands");
                int reg = operands[0].Reg;
                bytes.Add((byte)(0x48 + ((reg >> 3) & 1))); // REX.W + REX.B
                bytes.Add((byte)(0x81));
                bytes.Add((byte)(0xC0 + (reg & 7)));
                bytes.AddRange(BitConverter.GetBytes((uint)operands[1].Imm32));
                break;
            }

            case OpCode.SUB_R64_IMM32:
            {
                if (operands.Length != 2) throw new ArgumentException("SUB_R64_IMM32 needs 2 operands");
                int reg = operands[0].Reg;
                bytes.Add((byte)(0x48 + ((reg >> 3) & 1)));
                bytes.Add(0x81);
                bytes.Add((byte)(0xE8 + (reg & 7)));
                bytes.AddRange(BitConverter.GetBytes((uint)operands[1].Imm32));
                break;
            }

            case OpCode.SUB_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("SUB_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x2B); // SUB r64, r/m64
                bytes.Add((byte)(0xC0 + (dst & 7) * 8 + (src & 7)));
                break;
            }

            case OpCode.CMP_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("CMP_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x3B);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.CMP_R64_IMM32:
            {
                if (operands.Length != 2) throw new ArgumentException("CMP_R64_IMM32 needs 2 operands");
                int reg = operands[0].Reg;
                bytes.Add((byte)(0x48 + ((reg >> 3) & 1)));
                bytes.Add(0x81);
                bytes.Add((byte)(0xF8 + (reg & 7)));
                bytes.AddRange(BitConverter.GetBytes((uint)operands[1].Imm32));
                break;
            }

            case OpCode.TEST_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("TEST_R64_R64 needs 2 operands");
                int a = operands[0].Reg;
                int b = operands[1].Reg;
                int rexB = (b >> 3) & 1;
                int rexR = (a >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x85);
                bytes.Add((byte)(0xC0 + (((a & 7) << 3) | (b & 7))));
                break;
            }

            case OpCode.XOR_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("XOR_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x33);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.IMUL_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("IMUL_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexB = (src >> 3) & 1;
                int rexR = (dst >> 3) & 1;
                bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                bytes.Add(0x0F);
                bytes.Add(0xAF);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.AND_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("AND_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                bytes.Add((byte)(0x48 + ((src >> 3) & 1) + ((dst >> 3) << 2)));
                bytes.Add(0x23);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.OR_R64_R64:
            {
                if (operands.Length != 2) throw new ArgumentException("OR_R64_R64 needs 2 operands");
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                bytes.Add((byte)(0x48 + ((src >> 3) & 1) + ((dst >> 3) << 2)));
                bytes.Add(0x0B);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.PUSH_R64:
            {
                int reg = operands.Length > 0 ? operands[0].Reg : 0;
                if (reg >= 8) bytes.Add(0x41);
                bytes.Add((byte)(0x50 + (reg & 7)));
                break;
            }

            case OpCode.POP_R64:
            {
                int reg = operands.Length > 0 ? operands[0].Reg : 0;
                if (reg >= 8) bytes.Add(0x41);
                bytes.Add((byte)(0x58 + (reg & 7)));
                break;
            }

            case OpCode.PUSH_IMM32:
            {
                bytes.Add(0x68);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.PUSH_RSP:
            {
                bytes.Add(0x50);
                break;
            }

            case OpCode.CALL_REL32:
            {
                bytes.Add(0xE8);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.CALL_R64:
            {
                int reg = operands[0].Reg;
                bytes.Add(0xFF);
                bytes.Add((byte)(0xD0 + (reg & 7)));
                break;
            }

            case OpCode.RET:
            {
                bytes.Add(0xC3);
                break;
            }

            case OpCode.JMP_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0xEB);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JMP_REL32:
            {
                bytes.Add(0xE9);
                bytes.AddRange(BitConverter.GetBytes(operands[0].Imm32));
                break;
            }

            case OpCode.JE_REL8:
            case OpCode.JZ_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x74);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JNE_REL8:
            case OpCode.JNZ_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x75);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JE_REL32:
            case OpCode.JZ_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x84);
                bytes.AddRange(BitConverter.GetBytes(operands[0].Imm32));
                break;
            }

            case OpCode.JNE_REL32:
            case OpCode.JNZ_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x85);
                bytes.AddRange(BitConverter.GetBytes(operands[0].Imm32));
                break;
            }

            case OpCode.JG_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x7F);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JGE_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x7D);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JL_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x7C);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JLE_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x7E);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JG_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x8F);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.JGE_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x8D);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.JL_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x8C);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.JLE_REL32:
            {
                bytes.Add(0x0F);
                bytes.Add(0x8E);
                bytes.AddRange(BitConverter.GetBytes((uint)operands[0].Imm32));
                break;
            }

            case OpCode.JA_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x77);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.JB_REL8:
            {
                sbyte offset = operands[0].Imm8;
                bytes.Add(0x72);
                bytes.Add((byte)offset);
                break;
            }

            case OpCode.NOP:
            {
                bytes.Add(0x90);
                break;
            }

            case OpCode.INT3:
            {
                bytes.Add(0xCC);
                break;
            }

            case OpCode.MOVZX_R64_R32:
            {
                int dst = operands[0].Reg;
                int src = operands[1].Reg;
                int rexR = (dst >> 3) & 1;
                int rexB = (src >> 3) & 1;
                bytes.Add((byte)(0x45 + (rexR << 2) + rexB));
                bytes.Add(0x0F);
                bytes.Add(0xB6);
                bytes.Add((byte)(0xC0 + (((dst & 7) << 3) | (src & 7))));
                break;
            }

            case OpCode.SHIFT_LEFT:
            {
                int dst = operands[0].Reg;
                int sh = (int)operands[1].Imm64;
                if (sh == 1) { bytes.Add((byte)(0x48 + ((dst >> 3) & 1))); bytes.Add((byte)(0xD1)); bytes.Add((byte)(0xE0 + (dst & 7))); }
                else { bytes.Add((byte)(0x48 + ((dst >> 3) & 1))); bytes.Add(0xC1); bytes.Add((byte)(0xE0 + (dst & 7))); bytes.Add((byte)sh); }
                break;
            }

            case OpCode.SHIFT_RIGHT:
            {
                int dst = operands[0].Reg;
                int sh = (int)operands[1].Imm64;
                if (sh == 1) { bytes.Add((byte)(0x48 + ((dst >> 3) & 1))); bytes.Add((byte)(0xD1)); bytes.Add((byte)(0xE8 + (dst & 7))); }
                else { bytes.Add((byte)(0x48 + ((dst >> 3) & 1))); bytes.Add(0xC1); bytes.Add((byte)(0xE8 + (dst & 7))); bytes.Add((byte)sh); }
                break;
            }

            case OpCode.MOV_R64_IMM32_SIGNEXT:
            {
                int reg = operands[0].Reg;
                uint val = operands[1].Imm32;
                bytes.Add((byte)(0x48 + ((reg >> 3) & 1)));
                bytes.Add((byte)(0xC7));
                bytes.Add((byte)(0xC0 + (reg & 7)));
                bytes.AddRange(BitConverter.GetBytes(val));
                break;
            }

            case OpCode.LEA_R64_MEM:
            {
                int dst = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                int rexR = (dst >> 3) & 1;

                if (baseReg == 255) // RIP-relative
                {
                    int disp = operands[1].Disp;
                    bytes.Add((byte)(0x48 + (rexR << 2)));
                    bytes.Add(0x8D);
                    bytes.Add((byte)(0x05 + ((dst & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int disp = operands[1].Disp;
                    int rexB = (baseReg >> 3) & 1;
                    bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                    bytes.Add(0x8D);
                    EncodeModrmSib(bytes, dst, baseReg, disp);
                }
                break;
            }

            case OpCode.MOVZX_R64_MEM8:
            {
                // movzx r64, byte [mem]
                int dst = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                int disp = operands[1].Disp;
                int rexR = (dst >> 3) & 1;

                if (baseReg == 255) // RIP-relative
                {
                    bytes.Add((byte)(0x48 + (rexR << 2)));
                    bytes.Add(0x0F);
                    bytes.Add(0xB6);
                    bytes.Add((byte)(0x05 + ((dst & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int rexB = (baseReg >> 3) & 1;
                    bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                    bytes.Add(0x0F);
                    bytes.Add(0xB6);
                    EncodeModrmSib(bytes, dst, baseReg, disp);
                }
                break;
            }

            case OpCode.CALL_RIPDISP:
            {
                // call [rip+disp32] — FF 15 rel32
                int disp = (int)operands[0].Imm32;
                bytes.Add(0xFF);
                bytes.Add(0x15);
                bytes.AddRange(BitConverter.GetBytes(disp));
                break;
            }

            case OpCode.MOV_R64_MEM_RIP:
            {
                // mov r64, [rip+disp32] — 48 8B 05 rel32 (or 8B 05 for 32-bit)
                int reg = operands[0].Reg;
                int disp = (int)operands[1].Imm32;
                bytes.Add((byte)(0x48 + ((reg >> 3) & 1))); // REX.W
                bytes.Add(0x8B);
                bytes.Add((byte)(0x05 + ((reg & 7) << 3))); // mod=00, rm=101
                bytes.AddRange(BitConverter.GetBytes(disp));
                break;
            }

            case OpCode.PREFETCHT0_RIPREL:
            {
                int disp = (int)operands[0].Imm32;
                bytes.Add(0x0F); bytes.Add(0x18); bytes.Add(0x0D); // T0: reg=1
                bytes.AddRange(BitConverter.GetBytes(disp));
                break;
            }
            case OpCode.PREFETCHT1_RIPREL:
            {
                int disp = (int)operands[0].Imm32;
                bytes.Add(0x0F); bytes.Add(0x18); bytes.Add(0x15); // T1: reg=2
                bytes.AddRange(BitConverter.GetBytes(disp));
                break;
            }
            case OpCode.PREFETCHT2_RIPREL:
            {
                int disp = (int)operands[0].Imm32;
                bytes.Add(0x0F); bytes.Add(0x18); bytes.Add(0x1D); // T2: reg=3
                bytes.AddRange(BitConverter.GetBytes(disp));
                break;
            }

            case OpCode.MOVZX_R64_MEM16:
            {
                // movzx r64, word [mem] — 0F B7 /r
                int dst = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                int disp = operands[1].Disp;
                int rexR = (dst >> 3) & 1;

                if (baseReg == 255) // RIP-relative
                {
                    bytes.Add((byte)(0x48 + (rexR << 2)));
                    bytes.Add(0x0F); bytes.Add(0xB7);
                    bytes.Add((byte)(0x05 + ((dst & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int rexB = (baseReg >> 3) & 1;
                    byte rex = (byte)(rexB | (rexR << 2));
                    if (rex != 0) bytes.Add((byte)(0x40 | rex));
                    bytes.Add(0x0F); bytes.Add(0xB7);
                    EncodeModrmSib(bytes, dst, baseReg, disp);
                }
                break;
            }

            case OpCode.MOVSX_R64_MEM8:
            {
                // movsx r64, byte [mem] — REX.W 0F BE /r
                int dst = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                int disp = operands[1].Disp;
                int rexR = (dst >> 3) & 1;

                if (baseReg == 255)
                {
                    bytes.Add((byte)(0x48 + (rexR << 2)));
                    bytes.Add(0x0F); bytes.Add(0xBE);
                    bytes.Add((byte)(0x05 + ((dst & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int rexB = (baseReg >> 3) & 1;
                    bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                    bytes.Add(0x0F); bytes.Add(0xBE);
                    EncodeModrmSib(bytes, dst, baseReg, disp);
                }
                break;
            }

            case OpCode.MOVSX_R64_MEM16:
            {
                // movsx r64, word [mem] — REX.W 0F BF /r
                int dst = operands[0].Reg;
                int baseReg = operands[1].BaseReg;
                int disp = operands[1].Disp;
                int rexR = (dst >> 3) & 1;

                if (baseReg == 255)
                {
                    bytes.Add((byte)(0x48 + (rexR << 2)));
                    bytes.Add(0x0F); bytes.Add(0xBF);
                    bytes.Add((byte)(0x05 + ((dst & 7) << 3)));
                    bytes.AddRange(BitConverter.GetBytes(disp));
                }
                else
                {
                    int rexB = (baseReg >> 3) & 1;
                    bytes.Add((byte)(0x48 + rexB + (rexR << 2)));
                    bytes.Add(0x0F); bytes.Add(0xBF);
                    EncodeModrmSib(bytes, dst, baseReg, disp);
                }
                break;
            }

            case OpCode.MOV_MEM_R8:
            {
                // mov byte [mem], reg — 88 /r
                int baseReg = operands[0].BaseReg;
                int src = operands[1].Reg;
                int disp = operands[0].Disp;
                int rexB = (baseReg >> 3) & 1;
                int rexR = (src >> 3) & 1;
                byte rex = (byte)(rexB | (rexR << 2));
                if (rex != 0) bytes.Add((byte)(0x40 | rex));
                bytes.Add(0x88);
                EncodeModrmSib(bytes, src, baseReg, disp);
                break;
            }

            case OpCode.MOV_MEM_R16:
            {
                // mov word [mem], reg — 66 89 /r
                int baseReg = operands[0].BaseReg;
                int src = operands[1].Reg;
                int disp = operands[0].Disp;
                int rexB = (baseReg >> 3) & 1;
                int rexR = (src >> 3) & 1;
                bytes.Add(0x66);
                byte rex = (byte)(rexB | (rexR << 2));
                if (rex != 0) bytes.Add((byte)(0x40 | rex));
                bytes.Add(0x89);
                EncodeModrmSib(bytes, src, baseReg, disp);
                break;
            }

            case OpCode.MOV_MEM_R32:
            {
                // mov dword [mem], reg — 89 /r
                int baseReg = operands[0].BaseReg;
                int src = operands[1].Reg;
                int disp = operands[0].Disp;
                int rexB = (baseReg >> 3) & 1;
                int rexR = (src >> 3) & 1;
                byte rex = (byte)(rexB | (rexR << 2));
                if (rex != 0) bytes.Add((byte)(0x40 | rex));
                bytes.Add(0x89);
                EncodeModrmSib(bytes, src, baseReg, disp);
                break;
            }

            default:
                throw new NotSupportedException($"OpCode {op} not supported");
        }

        return bytes.ToArray();
    }

    private static void EncodeModrmSib(List<byte> bytes, int reg, int baseReg, int disp)
    {
        // Encodes [baseReg + disp] addressing into modrm + optional SIB + displacement
        // reg = register in the "reg" field of modrm
        // baseReg = base register for memory address (0-15)
        // disp = displacement value

        // hasDisp tracks whether displacement is 8-bit or 32-bit (0=none, 1=8bit, 2=32bit)
        int dispMode;
        if (disp == 0 && baseReg != Reg.RBP && baseReg != Reg.R13)
            dispMode = 0;
        else if (disp >= -128 && disp <= 127)
            dispMode = 1;
        else
            dispMode = 2;

        // mod field in ModRM: 0=no disp, 1=disp8, 2=disp32
        int mod = dispMode;

        if (baseReg == Reg.RSP || baseReg == Reg.R12)
        {
            // rm=100 signals SIB
            bytes.Add((byte)((mod << 6) | ((reg & 7) << 3) | 4));
            // SIB: scale=0, index=4(no index), base=baseReg
            bytes.Add((byte)((0 << 6) | (4 << 3) | (baseReg & 7)));
        }
        else
        {
            // rm = baseReg (no SIB needed)
            bytes.Add((byte)((mod << 6) | ((reg & 7) << 3) | (baseReg & 7)));
        }

        // Displacement bytes
        if (dispMode == 1)
            bytes.Add((byte)(sbyte)disp);
        else if (dispMode == 2)
            bytes.AddRange(BitConverter.GetBytes(disp));
        // dispMode == 0: no displacement (except RBP/R13 which use mod=01 disp8=0)
    }

    private static void AddDisplacement(List<byte> bytes, int disp)
    {
        // Legacy: just emit modrm/SIB + disp
        // This should not be called directly; use EncodeModrmSib instead.
        if (disp == 0)
        {
        }
        else if (disp >= -128 && disp <= 127)
        {
            bytes.Add((byte)disp);
        }
        else
        {
            bytes.AddRange(BitConverter.GetBytes(disp));
        }
    }

    public static void Emit(List<byte> code, OpCode op, params Operand[] operands)
    {
        byte[] encoded = Encode(op, operands);
        code.AddRange(encoded);
    }

    public static byte[] EncodeFunction(List<byte> code)
    {
        return code.ToArray();
    }

    public static string Disassemble(byte[] code, int offset = 0, int count = -1)
    {
        if (count < 0) count = code.Length - offset;
        var sb = new System.Text.StringBuilder();
        int i = offset;
        int end = offset + count;
        while (i < end && i < code.Length)
        {
            int start = i;
            sb.Append($"{i:X4}: ");
            int prefixCount = 0;
            while (prefixCount < 4 && i < code.Length)
            {
                byte b = code[i];
                if (b == 0x40 || b == 0x41 || b == 0x42 || b == 0x43 || b == 0x44 || b == 0x45 || b == 0x46 || b == 0x47 ||
                    b == 0x48 || b == 0x49 || b == 0x4A || b == 0x4B || b == 0x4C || b == 0x4D || b == 0x4E || b == 0x4F ||
                    b == 0x64 || b == 0x65 || b == 0x66 || b == 0x67)
                {
                    sb.Append($"{b:X2} ");
                    i++;
                    prefixCount++;
                    continue;
                }
                break;
            }
            if (i >= code.Length) break;

            byte opb = code[i];
            if (opb == 0x90) { sb.Append("nop"); i++; }
            else if (opb == 0xCC) { sb.Append("int3"); i++; }
            else if (opb == 0xC3) { sb.Append("ret"); i++; }
            else if (opb == 0xEB)
            {
                sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0);
                sb.Append($"jmp {i + 2 + off:X4}"); i += 2;
            }
            else if (opb == 0x74) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"je {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x75) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jne {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x7F) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jg {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x7D) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jge {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x7C) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jl {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x7E) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jle {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x77) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"ja {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0x72) { sbyte off = (sbyte)(i + 1 < code.Length ? code[i + 1] : 0); sb.Append($"jb {i + 2 + off:X4}"); i += 2; }
            else if (opb == 0xE8) { uint base2 = (uint)(i + 5); uint disp2 = i + 5 < code.Length ? BitConverter.ToUInt32(code, i + 1) : 0; sb.Append($"call {(base2 + disp2):X4}"); i += 5; }
            else if (opb == 0xE9) { uint base2 = (uint)(i + 5); uint disp2 = i + 5 < code.Length ? BitConverter.ToUInt32(code, i + 1) : 0; sb.Append($"jmp {(base2 + disp2):X4}"); i += 5; }
            else if (opb == 0x68) { uint imm = i + 5 < code.Length ? BitConverter.ToUInt32(code, i + 1) : 0; sb.Append($"push {imm}"); i += 5; }
            else if ((opb & 0xF8) == 0x50) { sb.Append($"push r{(opb & 7)}"); i++; }
            else if ((opb & 0xF8) == 0x58) { sb.Append($"pop r{(opb & 7)}"); i++; }
            else if (opb == 0xFF) { sb.Append("call r*"); i += 2; }
            else if (opb == 0x0F)
            {
                if (i + 1 < code.Length)
                {
                    byte op2 = code[i + 1];
                    if (op2 == 0x84) { uint base2 = (uint)(i + 6); uint disp2 = i + 6 < code.Length ? BitConverter.ToUInt32(code, i + 2) : 0; sb.Append($"je {(base2 + disp2):X4}"); i += 6; }
                    else if (op2 == 0x85) { uint base2 = (uint)(i + 6); uint disp2 = i + 6 < code.Length ? BitConverter.ToUInt32(code, i + 2) : 0; sb.Append($"jne {(base2 + disp2):X4}"); i += 6; }
                    else if (op2 == 0xAF) { sb.Append("imul r,r"); i += 3; }
                    else if (op2 == 0xB6) { sb.Append("movzx r,r"); i += 3; }
                    else { sb.Append($"0F {op2:X2}"); i += 2; }
                }
                else { i += 2; }
            }
            else if ((opb & 0xFC) == 0x48 && i + 1 < code.Length)
            {
                byte op2 = code[i + 1];
                if (op2 == 0x8B) { sb.Append("mov r,r"); i += 3; }
                else if (op2 == 0x89) { sb.Append("mov [r],r"); i += 3; }
                else if (op2 == 0x03) { sb.Append("add r,r"); i += 3; }
                else if (op2 == 0x33) { sb.Append("xor r,r"); i += 3; }
                else if (op2 == 0x23) { sb.Append("and r,r"); i += 3; }
                else if (op2 == 0x0B) { sb.Append("or r,r"); i += 3; }
                else if (op2 == 0x85) { sb.Append("test r,r"); i += 3; }
                else if (op2 == 0x3B) { sb.Append("cmp r,r"); i += 3; }
                else if (op2 == 0x8D) { sb.Append("lea r,[r]"); i += 4; }
                else if (op2 == 0xC7) { sb.Append("mov r,imm32"); i += 6; }
                else if (op2 == 0xD1 || op2 == 0xC1) { sb.Append("shift r,imm"); i += 4; }
                else { sb.Append($"48 {op2:X2}"); i += 2; }
            }
            else if ((opb & 0xF8) == 0xB8)
            {
                int reg = opb & 7;
                int imm = i + 5 < code.Length ? (int)BitConverter.ToUInt64(code, i + 1) : 0;
                sb.Append($"mov r{reg}, {imm:X}"); i += 9;
            }
            else if (opb == 0x81)
            {
                if (i + 1 < code.Length)
                {
                    byte modrm = code[i + 1];
                    sb.Append($"op r{modrm & 7},imm32"); i += 6;
                }
                else i += 6;
            }
            else
            {
                sb.Append($"{opb:X2}");
                i++;
            }
            sb.AppendLine();
        }
        return sb.ToString();
    }
}

public enum OpCode
{
    NOP,
    INT3,
    RET,
    CALL_REL32,
    CALL_R64,
    JMP_REL8,
    JMP_REL32,
    JE_REL8, JZ_REL8,
    JNE_REL8, JNZ_REL8,
    JE_REL32, JZ_REL32,
    JNE_REL32, JNZ_REL32,
    JG_REL8,
    JGE_REL8,
    JL_REL8,
    JLE_REL8,
    JG_REL32,
    JGE_REL32,
    JL_REL32,
    JLE_REL32,
    JA_REL8,
    JB_REL8,
    PUSH_R64,
    POP_R64,
    PUSH_IMM32,
    PUSH_RSP,
    MOV_R64_IMM64,
    MOV_R64_IMM32_SIGNEXT,
    MOV_R64_R64,
    MOV_R64_MEM,
    MOV_R32_MEM,
    MOV_MEM_R64,
    MOVZX_R64_R32,
    ADD_R64_R64,
    ADD_R64_IMM32,
    SUB_R64_IMM32,
    SUB_R64_R64,
    CMP_R64_R64,
    CMP_R64_IMM32,
    TEST_R64_R64,
    XOR_R64_R64,
    IMUL_R64_R64,
    AND_R64_R64,
    OR_R64_R64,
    SHIFT_LEFT,
    SHIFT_RIGHT,
    LEA_R64_MEM,
    MOVZX_R64_MEM8,
    CALL_RIPDISP,
    MOV_R64_MEM_RIP,
    PREFETCHT0_RIPREL,
    PREFETCHT1_RIPREL,
    PREFETCHT2_RIPREL,
    MOVZX_R64_MEM16,
    MOVSX_R64_MEM8,
    MOVSX_R64_MEM16,
    MOV_MEM_R8,
    MOV_MEM_R16,
    MOV_MEM_R32,
}

public struct Operand
{
    public int Reg;
    public long Imm64;
    public uint Imm32;
    public sbyte Imm8 => (sbyte)Imm64;
    public int BaseReg;
    public int IndexReg;
    public int Scale;
    public int Disp;

    public static Operand R(int reg) => new() { Reg = reg };
    public static Operand Imm(long v) => new() { Imm64 = v };
    public static Operand ImmU32(uint v) => new() { Imm32 = v };
    public static Operand Mem(int baseReg, int disp = 0, int indexReg = -1, int scale = 1)
        => new() { BaseReg = baseReg, IndexReg = indexReg, Scale = scale, Disp = disp };

    public static readonly Operand RAX = R(0);
    public static readonly Operand RCX = R(1);
    public static readonly Operand RDX = R(2);
    public static readonly Operand RBX = R(3);
    public static readonly Operand RSP = R(4);
    public static readonly Operand RBP = R(5);
    public static readonly Operand RSI = R(6);
    public static readonly Operand RDI = R(7);
    public static readonly Operand R8 = R(8);
    public static readonly Operand R9 = R(9);
    public static readonly Operand R10 = R(10);
    public static readonly Operand R11 = R(11);
    public static readonly Operand R12 = R(12);
    public static readonly Operand R13 = R(13);
    public static readonly Operand R14 = R(14);
    public static readonly Operand R15 = R(15);
    public static readonly Operand RIP = R(255);
}

public static class Reg
{
    public const int RAX = 0; public const int RCX = 1; public const int RDX = 2; public const int RBX = 3;
    public const int RSP = 4; public const int RBP = 5; public const int RSI = 6; public const int RDI = 7;
    public const int R8 = 8; public const int R9 = 9; public const int R10 = 10; public const int R11 = 11;
    public const int R12 = 12; public const int R13 = 13; public const int R14 = 14; public const int R15 = 15;
}