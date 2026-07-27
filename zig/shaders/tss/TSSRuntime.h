#pragma once

#include "CoreMinimal.h"
#include "RenderGraph.h"

class FTSSRuntime
{
public:
	FTSSRuntime();

	void ExecutePlan(FRDGBuilder& GraphBuilder, FRDGTextureRef SceneColor, FRDGTextureRef ViewFamilyOutput, FRDGTextureRef Velocity, FRDGTextureRef SceneDepth, FIntPoint DisplaySize, float DownscaleFactor = 1.0f, const FVector4f& InPrevVP0 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP1 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP2 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InPrevVP3 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP0 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP1 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP2 = FVector4f(EForceInit::ForceInitToZero), const FVector4f& InCurrInvVP3 = FVector4f(EForceInit::ForceInitToZero), bool bInHasValidPrevFrame = false);

	FRDGTextureRef GetLastFinalOutput() const { return LastFinalOutput; }

private:
	void ExecuteComputePass(FRDGBuilder& GraphBuilder, const FString& PassName, const FString& ShaderName, TArray<FRDGTextureRef>& Inputs, TArray<FString>& OutputNames, TArray<FRDGTextureRef>& OutputTexs, TArray<FRDGTextureUAV*>& OutputUAVs, FIntPoint DispatchSize, int32 GroupSizeX, bool bLog);

	TRefCountPtr<IPooledRenderTarget> HistoryRT;
	TRefCountPtr<IPooledRenderTarget> LockHistoryRT;
	TRefCountPtr<IPooledRenderTarget> DilatedVelocityRT;
	TRefCountPtr<IPooledRenderTarget> LumaHistoryRT;
	TRefCountPtr<IPooledRenderTarget> AutoExposureRT;
	FRDGTextureRef LastFinalOutput = nullptr;
	FIntPoint PreviousRenderSize = FIntPoint::ZeroValue;
	float PreviousDownscale = 1.0f;
	FVector4f PrevVPRow0 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f PrevVPRow1 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f PrevVPRow2 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f PrevVPRow3 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f CurrInvVPRow0 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f CurrInvVPRow1 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f CurrInvVPRow2 = FVector4f(EForceInit::ForceInitToZero);
	FVector4f CurrInvVPRow3 = FVector4f(EForceInit::ForceInitToZero);
	bool bHasValidPrevFrame = false;
	double LastLogTime = 0.0;
};
