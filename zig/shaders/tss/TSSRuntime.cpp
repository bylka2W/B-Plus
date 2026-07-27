#include "TSSRuntime.h"
#include "TSSShaders.h"
#include "Misc/Paths.h"
#include "RHIStaticStates.h"

FTSSRuntime::FTSSRuntime()
{
}

static EPixelFormat GetOutputFormat(const FString& ResName, EPixelFormat InputFmt)
{
	if (InputFmt == PF_B8G8R8A8) return PF_FloatRGBA;
	return InputFmt;
}

static FIntPoint GetOutputSizeForName(const FString& Name, FIntPoint RenderSize, FIntPoint DisplaySize)
{
	return RenderSize;
}

void FTSSRuntime::ExecutePlan(FRDGBuilder& GraphBuilder, FRDGTextureRef SceneColor, FRDGTextureRef ViewFamilyOutput, FRDGTextureRef Velocity, FRDGTextureRef SceneDepth, FIntPoint DisplaySize, float DownscaleFactor, const FVector4f& InPrevVP0, const FVector4f& InPrevVP1, const FVector4f& InPrevVP2, const FVector4f& InPrevVP3, const FVector4f& InCurrInvVP0, const FVector4f& InCurrInvVP1, const FVector4f& InCurrInvVP2, const FVector4f& InCurrInvVP3, bool bInHasValidPrevFrame)
{
	PrevVPRow0 = InPrevVP0;
	PrevVPRow1 = InPrevVP1;
	PrevVPRow2 = InPrevVP2;
	PrevVPRow3 = InPrevVP3;
	CurrInvVPRow0 = InCurrInvVP0;
	CurrInvVPRow1 = InCurrInvVP1;
	CurrInvVPRow2 = InCurrInvVP2;
	CurrInvVPRow3 = InCurrInvVP3;
	bHasValidPrevFrame = bInHasValidPrevFrame;

	bool bIsUpscale = DownscaleFactor > 0.0f && DownscaleFactor < (1.0f - SMALL_NUMBER);
	bool bIsNative = FMath::IsNearlyEqual(DownscaleFactor, 1.0f, 0.005f);
	bool bIsSupersampling = !bIsUpscale && !bIsNative;

	FIntPoint RenderSize = DisplaySize;
	if (bIsUpscale)
	{
		RenderSize.X = FMath::Max(1, FMath::CeilToInt(DisplaySize.X * DownscaleFactor));
		RenderSize.Y = FMath::Max(1, FMath::CeilToInt(DisplaySize.Y * DownscaleFactor));

		if (RenderSize != SceneColor->Desc.Extent)
		{
			FRDGTextureRef Downscaled = GraphBuilder.CreateTexture(
				FRDGTextureDesc::Create2D(RenderSize, SceneColor->Desc.Format,
					FClearValueBinding::None,
					TexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource),
				TEXT("TSS_DownscaledScene")
			);
			FRDGTextureUAVRef DownUAV = GraphBuilder.CreateUAV(Downscaled);

			TShaderMapRef<FTSSShader_Copy> CopyShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));
			FBPlusShaderParams* CopyParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();
			CopyParams->Input0 = SceneColor;
			CopyParams->Output0 = DownUAV;
			CopyParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();

			FIntVector GroupCount = FComputeShaderUtils::GetGroupCount(RenderSize, 8);
			GraphBuilder.AddPass(
				RDG_EVENT_NAME("TSS_Downscale"),
				CopyParams, ERDGPassFlags::Compute,
				[CopyShader, CopyParams, GroupCount](FRHIComputeCommandList& Cmd)
				{
					FComputeShaderUtils::Dispatch(Cmd, CopyShader, *CopyParams, GroupCount);
				});

			SceneColor = Downscaled;
		}
	}
	else if (bIsSupersampling)
	{
		RenderSize.X = FMath::Max(1, FMath::CeilToInt(DisplaySize.X * DownscaleFactor));
		RenderSize.Y = FMath::Max(1, FMath::CeilToInt(DisplaySize.Y * DownscaleFactor));
	}

	bool bCacheValid = (PreviousRenderSize == RenderSize && FMath::IsNearlyEqual(PreviousDownscale, DownscaleFactor));

	double Now = FPlatformTime::Seconds();
	bool bLogThisFrame = (Now - LastLogTime > 1.0);
	if (bLogThisFrame)
	{
		LastLogTime = Now;
		const TCHAR* ModeStr = bIsUpscale ? TEXT("UPSCALE") : (bIsSupersampling ? TEXT("SUPERSAMPLE") : TEXT("NATIVE"));
		UE_LOG(LogTemp, Warning, TEXT("TSS: ===== %s Display=%dx%d -> Render=%dx%d (DF=%.2f) Cache=%d ====="),
			ModeStr, DisplaySize.X, DisplaySize.Y,
			RenderSize.X, RenderSize.Y, DownscaleFactor, bCacheValid ? 1 : 0);
	}

	TMap<FString, FRDGTextureRef> TextureCache;
	TextureCache.Add(TEXT("SceneColor"), SceneColor);
	TextureCache.Add(TEXT("ViewFamilyOutput"), ViewFamilyOutput);
	TextureCache.Add(TEXT("Velocity"), Velocity);
	TextureCache.Add(TEXT("SceneDepth"), SceneDepth);

	if (HistoryRTRT.IsValid() && bCacheValid && !bIsNative)
	{
		FRDGTextureRef HistoryTex = GraphBuilder.RegisterExternalTexture(HistoryRTRT, TEXT("TSS_History"));
		TextureCache.Add(TEXT("History"), HistoryTex);
	}
	else
	{
		FRDGTextureRef InitHistory = GraphBuilder.CreateTexture(
			FRDGTextureDesc::Create2D(History, DisplaySize,
				FClearValueBinding::None,
				TexCreate_UAV | TexCreate_ShaderResource),
			TEXT("TSS_History_Init"));
		TextureCache.Add(TEXT("History"), InitHistory);
	}

	if (LockHistoryRTRT.IsValid() && bCacheValid && !bIsNative)
	{
		FRDGTextureRef LockStatusTex = GraphBuilder.RegisterExternalTexture(LockHistoryRTRT, TEXT("TSS_Lock"));
		TextureCache.Add(TEXT("LockStatus"), LockStatusTex);
	}
	else
	{
		FRDGTextureRef InitLockStatus = GraphBuilder.CreateTexture(
			FRDGTextureDesc::Create2D(LockStatus, DisplaySize,
				FClearValueBinding::None,
				TexCreate_UAV | TexCreate_ShaderResource),
			TEXT("TSS_Lock_Init"));
		TextureCache.Add(TEXT("LockStatus"), InitLockStatus);
	}

	if (DilatedVelocityRTRT.IsValid() && bCacheValid && !bIsNative)
	{
		FRDGTextureRef DilatedMotionVectorsTex = GraphBuilder.RegisterExternalTexture(DilatedVelocityRTRT, TEXT("TSS_PrevDilatedMV"));
		TextureCache.Add(TEXT("DilatedMotionVectors"), DilatedMotionVectorsTex);
	}
	else
	{
		FRDGTextureRef InitDilatedMotionVectors = GraphBuilder.CreateTexture(
			FRDGTextureDesc::Create2D(DilatedMotionVectors, RenderSize,
				FClearValueBinding::None,
				TexCreate_UAV | TexCreate_ShaderResource),
			TEXT("TSS_PrevDilatedMV_Init"));
		TextureCache.Add(TEXT("DilatedMotionVectors"), InitDilatedMotionVectors);
	}

	if (LumaHistoryRTRT.IsValid() && bCacheValid && !bIsNative)
	{
		FRDGTextureRef LumaHistoryTex = GraphBuilder.RegisterExternalTexture(LumaHistoryRTRT, TEXT("TSS_LumaHistory"));
		TextureCache.Add(TEXT("LumaHistory"), LumaHistoryTex);
	}
	else
	{
		FRDGTextureRef InitLumaHistory = GraphBuilder.CreateTexture(
			FRDGTextureDesc::Create2D(LumaHistory, DisplaySize,
				FClearValueBinding::None,
				TexCreate_UAV | TexCreate_ShaderResource),
			TEXT("TSS_LumaHistory_Init"));
		TextureCache.Add(TEXT("LumaHistory"), InitLumaHistory);
	}

	if (AutoExposureRTRT.IsValid() && bCacheValid && !bIsNative)
	{
		FRDGTextureRef ExposureTex = GraphBuilder.RegisterExternalTexture(AutoExposureRTRT, TEXT("TSS_PrevExposure"));
		TextureCache.Add(TEXT("Exposure"), ExposureTex);
	}
	else
	{
		FRDGTextureRef InitExposure = GraphBuilder.CreateTexture(
			FRDGTextureDesc::Create2D(Exposure, FIntPoint(1, 1),
				FClearValueBinding::None,
				TexCreate_UAV | TexCreate_ShaderResource),
			TEXT("TSS_PrevExposure_Init"));
		TextureCache.Add(TEXT("Exposure"), InitExposure);
	}

	PreviousRenderSize = RenderSize;
	PreviousDownscale = DownscaleFactor;

	if (bIsNative)
	{
		FRDGTextureDesc EASUDesc = FRDGTextureDesc::Create2D(
			DisplaySize, SceneColor->Desc.Format,
			FClearValueBinding::None,
			TexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureRef EASUOutput = GraphBuilder.CreateTexture(EASUDesc, TEXT("TSS_EASU_Output"));

		TShaderMapRef<FTSSShader_EASU> EASUShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));
		FBPlusShaderParams* EASUParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();
		EASUParams->Input0 = SceneColor;
		EASUParams->Output0 = GraphBuilder.CreateUAV(EASUOutput);
		EASUParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();

		FIntVector EASUGroups = FComputeShaderUtils::GetGroupCount(DisplaySize, 8);
		GraphBuilder.AddPass(
			RDG_EVENT_NAME("TSS_EASU_Native"),
			EASUParams, ERDGPassFlags::Compute,
			[EASUShader, EASUParams, EASUGroups](FRHIComputeCommandList& Cmd)
			{
				FComputeShaderUtils::Dispatch(Cmd, EASUShader, *EASUParams, EASUGroups);
			});

		FRDGTextureDesc FinalDesc = FRDGTextureDesc::Create2D(
			DisplaySize, SceneColor->Desc.Format,
			FClearValueBinding::None,
			TexCreate_UAV | TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureRef FinalTex = GraphBuilder.CreateTexture(FinalDesc, TEXT("TSS_Final_Output"));

		TShaderMapRef<FTSSShader_RCAS> RCASShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));
		FBPlusShaderParams* RCASParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();
		RCASParams->Input0 = EASUOutput;
		RCASParams->Output0 = GraphBuilder.CreateUAV(FinalTex);
		RCASParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();

		FIntVector RCASGroups = FComputeShaderUtils::GetGroupCount(DisplaySize, 8);
		GraphBuilder.AddPass(
			RDG_EVENT_NAME("TSS_RCAS_Native"),
			RCASParams, ERDGPassFlags::Compute,
			[RCASShader, RCASParams, RCASGroups](FRHIComputeCommandList& Cmd)
			{
				FComputeShaderUtils::Dispatch(Cmd, RCASShader, *RCASParams, RCASGroups);
			});

		LastFinalOutput = FinalTex;
		PreviousRenderSize = RenderSize;
		PreviousDownscale = DownscaleFactor;
		return;
	}

	// === Plan/Metal Generated passes ===
	FRDGTextureRef* FinalTex = TextureCache.Find(TEXT("Final_Output"));
	if (FinalTex && *FinalTex) LastFinalOutput = *FinalTex;

	FRDGTextureRef* InternalUpscaled = TextureCache.Find(TEXT("InternalUpscaled"));
	if (InternalUpscaled && *InternalUpscaled) GraphBuilder.QueueTextureExtraction(*InternalUpscaled, &HistoryRT);

	FRDGTextureRef* LockStatOut = TextureCache.Find(TEXT("LockStatusOut"));
	if (LockStatOut && *LockStatOut) GraphBuilder.QueueTextureExtraction(*LockStatOut, &LockHistoryRT);

	FRDGTextureRef* DilatedMV = TextureCache.Find(TEXT("DilatedMotionVectors"));
	if (DilatedMV && *DilatedMV) GraphBuilder.QueueTextureExtraction(*DilatedMV, &DilatedVelocityRT);

	FRDGTextureRef* LumaHistOut = TextureCache.Find(TEXT("LumaHistoryOut"));
	if (LumaHistOut && *LumaHistOut) GraphBuilder.QueueTextureExtraction(*LumaHistOut, &LumaHistoryRT);

	FRDGTextureRef* ExposureTex = TextureCache.Find(TEXT("Exposure"));
	if (ExposureTex && *ExposureTex) GraphBuilder.QueueTextureExtraction(*ExposureTex, &AutoExposureRT);
}

void FTSSRuntime::ExecuteComputePass(FRDGBuilder& GraphBuilder, const FString& PassName, const FString& ShaderName, TArray<FRDGTextureRef>& Inputs, TArray<FString>& OutputNames, TArray<FRDGTextureRef>& OutputTexs, TArray<FRDGTextureUAV*>& OutputUAVs, FIntPoint DispatchSize, int32 GroupSizeX, bool bLog)
{
	RDG_EVENT_SCOPE(GraphBuilder, "TSS_BPlus_%s", *PassName);
	FBPlusShaderParams* Params = GraphBuilder.AllocParameters<FBPlusShaderParams>();
	// ... input/output binding ...
	FIntVector GroupCount = FComputeShaderUtils::GetGroupCount(DispatchSize, GroupSizeX);
#define TSS_DISPATCH_CASE(Name, ShaderClass) \
	if (ShaderName == TEXT(Name)) { \
		TShaderMapRef<ShaderClass> Shader_(GetGlobalShaderMap(GMaxRHIFeatureLevel)); \
		GraphBuilder.AddPass( \
			RDG_EVENT_NAME("BPlus_%s", *ShaderName), \
			Params, ERDGPassFlags::Compute, \
			[Shader_, Params, GroupCount](FRHIComputeCommandList& Cmd) \
			{ \
				FComputeShaderUtils::Dispatch(Cmd, Shader_, *Params, GroupCount); \
			}); \
	} else

	{
		UE_LOG(LogTemp, Fatal, TEXT("TSS: No shader for '%s'"), *ShaderName);
	}
#undef TSS_DISPATCH_CASE
}
