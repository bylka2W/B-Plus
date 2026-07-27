#pragma once

#include "CoreMinimal.h"
#include "DataDrivenShaderPlatformInfo.h"
#include "RenderGraph.h"
#include "GlobalShader.h"
#include "ShaderParameterStruct.h"

BEGIN_SHADER_PARAMETER_STRUCT(FBPlusShaderParams, )
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input0)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input1)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input2)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input3)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input4)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input5)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input6)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input7)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input8)
	SHADER_PARAMETER_RDG_TEXTURE(Texture2D<float4>, Input9)
	SHADER_PARAMETER_SAMPLER(SamplerState, InputSampler)
	SHADER_PARAMETER(FVector4f, PrevVPRow0)
	SHADER_PARAMETER(FVector4f, PrevVPRow1)
	SHADER_PARAMETER(FVector4f, PrevVPRow2)
	SHADER_PARAMETER(FVector4f, PrevVPRow3)
	SHADER_PARAMETER(FVector4f, CurrInvVPRow0)
	SHADER_PARAMETER(FVector4f, CurrInvVPRow1)
	SHADER_PARAMETER(FVector4f, CurrInvVPRow2)
	SHADER_PARAMETER(FVector4f, CurrInvVPRow3)
	SHADER_PARAMETER(uint32, bHasValidPrevFrame)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output0)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output1)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output2)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output3)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output4)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output5)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output6)
	SHADER_PARAMETER_RDG_TEXTURE_UAV(RWTexture2D<float4>, Output7)
END_SHADER_PARAMETER_STRUCT()

#define TSS_DECLARE_SHADER(ClassName, VirtualPath, EntryPoint) \
class ClassName : public FGlobalShader \
{ \
public: \
	DECLARE_GLOBAL_SHADER(ClassName); \
	SHADER_USE_PARAMETER_STRUCT(ClassName, FGlobalShader); \
	using FParameters = FBPlusShaderParams; \
	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters) \
	{ \
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5); \
	} \
};

TSS_DECLARE_SHADER(FTSSShader_Copy, "/Plugin/TSS/Private/TSSCopy.usf", "CopyMain")
TSS_DECLARE_SHADER(FTSSShader_EASU, "/Plugin/TSS/Private/TSSEASU.usf", "EASUMain")
