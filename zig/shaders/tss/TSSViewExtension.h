#pragma once

#include "CoreMinimal.h"
#include "SceneViewExtension.h"

struct FPostProcessingInputs;
class FTSSRuntime;

class FTSSViewExtension : public FSceneViewExtensionBase
{
public:
	FTSSViewExtension(const FAutoRegister& AutoRegister);
	virtual ~FTSSViewExtension();

	virtual void SetupViewFamily(FSceneViewFamily& InViewFamily) override {}
	virtual void SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView) override {}
	virtual void BeginRenderViewFamily(FSceneViewFamily& InViewFamily) override {}
	virtual void PreRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& InView) override;
	virtual void PreRenderViewFamily_RenderThread(FRDGBuilder& GraphBuilder, FSceneViewFamily& InViewFamily) override {}
	virtual void PrePostProcessPass_RenderThread(FRDGBuilder& GraphBuilder, const FSceneView& View, const FPostProcessingInputs& Inputs) override;
	virtual void PostRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& View) override;
	virtual bool IsActiveThisFrame_Internal(const FSceneViewExtensionContext& Context) const override { return true; }

public:
	float GetDownscaleFactor() const;
	void SetDownscaleFactor(float Factor);

private:
	static float Halton(int32 Index, int32 Base);

private:
	FTSSRuntime* Runtime = nullptr;
	float DownscaleFactor = 1.0f;
	FMatrix44f PrevFrameWorldToClip = FMatrix44f(EForceInit::ForceInitToZero);
	bool bUsePrevFrame = false;
	int32 JitterFrameIndex = 0;
	FVector2f CurrentJitter = FVector2f(0, 0);
	FVector2f PreviousJitter = FVector2f(0, 0);
	FRDGTextureRef LastViewFamilyOutput = nullptr;
};
